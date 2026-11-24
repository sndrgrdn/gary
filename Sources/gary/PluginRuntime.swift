import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

actor PluginRuntime: Subscriber {
    let bundle: PluginBundle
    let kind: PluginKind
    let hub: StateHub
    let deliver: @Sendable (PluginRuntime, RuntimeEvent) -> Void
    nonisolated let queue: DispatchSerialQueue
    nonisolated let engine: PluginEngine
    private let transpiler: Transpiler
    private var functions: PluginFunctions?
    private var exception: String?
    private var state: StateText
    var timers: [Int: @Sendable () -> Void] = [:]
    let startTimer: StartTimer
    private var stops: [() -> Void] = []
    var nextTimer = 1
    private var replies: [Int: (method: String, reply: @Sendable (Response) -> Void)] = [:]
    private var nextReply = 1
    let initialScene: Scene
    private var scene: Scene
    private var output = RuntimeOutput()
    private(set) var origin: CGRect?
    private var timings = Timings()
    var entryTrace: UInt64 = 0
    nonisolated let metrics = PluginMetrics()

    init(
        bundle: PluginBundle,
        kind: PluginKind,
        scene: Scene,
        settings: JSON,
        theme: JSON,
        hub: StateHub,
        deliver: @escaping @Sendable (PluginRuntime, RuntimeEvent) -> Void,
        engine: PluginEngine,
        transpiler: Transpiler = .shared,
        startTimer: @escaping StartTimer = dispatchTimer,
    ) {
        self.bundle = bundle
        self.kind = kind
        self.scene = scene
        initialScene = scene
        state = StateText(settings: settings, theme: theme)
        self.hub = hub
        self.deliver = deliver
        self.engine = engine
        self.transpiler = transpiler
        self.startTimer = startTimer
        queue = DispatchSerialQueue(label: "gary.plugin.\(bundle.manifest.id)", qos: kind.isSurface ? .userInitiated : .utility, target: engine.queue)
    }
}

extension PluginRuntime: SlotRuntime {}

nonisolated extension PluginRuntime {
    var id: PluginID {
        bundle.manifest.id
    }

    var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func onQueue(_ work: @escaping @Sendable (isolated PluginRuntime) -> Void) {
        queue.async { self.assumeIsolated(work) }
    }

    func load(_ trace: Trace) {
        onQueue { $0.start(trace) }
    }

    func stop(_ trace: Trace? = nil) {
        onQueue { runtime in
            runtime.entryTrace = trace?.id ?? 0
            runtime.teardown()
        }
    }

    func setScene(_ scene: Scene, _ trace: Trace) {
        onQueue { runtime in
            runtime.scene = scene
            runtime.renderAll(trace, always: true)
        }
    }

    func setTheme(_ theme: JSON, _ trace: Trace) {
        onQueue { runtime in
            runtime.state.setTheme(theme)
            runtime.renderAll(trace)
        }
    }

    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        onQueue { $0.update(topic, value, trace) }
    }

    func call(_ method: String, _ arguments: [String], reply: @escaping @Sendable (Response) -> Void) {
        onQueue { $0.answer(method, arguments, reply: reply) }
    }
}

extension PluginRuntime {
    private func start(_ trace: Trace) {
        entryTrace = trace.id
        let topics = hub.subscribe(self, to: bundle.manifest.subscriptions[kind] ?? [])
        let texts = Dictionary(uniqueKeysWithValues: topics.map { topic, value in (topic, timed(.encode) { state.set(topic, value) }) })
        do {
            let functions = try timed(.evaluate) { try evaluate() }
            for (topic, text) in texts.sorted(by: { $0.key.description < $1.key.description }) {
                try announce(topic, text, to: functions)
            }
            if kind.isSurface {
                try bundle.manifest.checkSurfaces(of: kind, exported: surfaces(functions).keys)
            }
            output = try renderOutput(functions)
            deliver(self, .loaded(output, traced(trace)))
            if !kind.isSurface {
                engine.dropCodeWhenQuiet()
            }
        } catch {
            teardown()
            deliver(self, .failed("\(error)"))
        }
    }

    private func update(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        let text = timed(.encode) { state.set(topic, value) }
        guard let functions else { return }
        entryTrace = trace.id
        do {
            try announce(topic, text, to: functions)
            renderAll(trace)
        } catch {
            fail("\(error)")
        }
    }

    private func announce(_ topic: Topic, _ text: String, to functions: PluginFunctions) throws {
        let arguments = "[{\"topic\":\(encode(.string(topic.description))),\"value\":\(text)}]"
        try invoke(functions.dispatch, .topic, ["onTopic", arguments, stateText(for: nil)], [.jsParse, .handler])
    }

    func handle(
        _ handler: String,
        _ arguments: [JSON],
        _ trace: Trace,
        origin: CGRect?,
        unhandled: (@MainActor @Sendable () -> Void)?,
    ) {
        guard let functions else { return }
        entryTrace = trace.id
        self.origin = origin
        defer { self.origin = nil }
        do {
            let handled = try invoke(functions.dispatch, .action, [handler, encode(JSON.array(arguments)), stateText(for: nil)], [.jsParse, .handler])
            if !handled.isNull {
                renderAll(trace)
            }
            if !handled.toBool(), let unhandled {
                DispatchQueue.main.async(execute: unhandled)
            }
        } catch {
            fail("\(error)")
        }
    }

    private func answer(_ method: String, _ arguments: [String], reply: @escaping @Sendable (Response) -> Void) {
        guard let functions else {
            reply(.failure("\(id) is not running"))
            return
        }
        let trace = Trace("call")
        entryTrace = trace.id
        let number = nextReply
        nextReply += 1
        replies[number] = (method, reply)
        let done: @convention(block) (Bool, String) -> Void = { [weak self] ok, text in
            self?.assumeIsolated { $0.replies.removeValue(forKey: number)?.reply(ok ? .ok(text) : .failure(text)) }
        }
        do {
            try invoke(functions.call, .call, [method, encode(JSON.array(arguments.map(JSON.string))), done], [.jsParse, .handler])
            renderAll(trace)
        } catch {
            replies.removeValue(forKey: number)?.reply(.failure("\(error)"))
        }
    }

    private func renderAll(_ trace: Trace, always: Bool = false) {
        guard let functions else { return }
        entryTrace = trace.id
        do {
            let next = try renderOutput(functions)
            let changed = timed(.compare) { next != output }
            TraceLog.note("render", trace.id, ["plugin": TraceLog.slot(slot), "changed": .bool(changed)])
            guard always || changed else {
                if tracing {
                    log("render plugin=\(id)/\(kind.rawValue) cause=\(trace.cause) unchanged \(traced(trace).timings.fields)")
                }
                return
            }
            output = next
            deliver(self, .output(next, traced(trace)))
        } catch {
            fail("\(error)")
        }
    }

    private func renderOutput(_ functions: PluginFunctions) throws -> RuntimeOutput {
        guard !scene.shown.isEmpty else { return RuntimeOutput() }
        let specs = kind.isSurface ? try surfaces(functions) : [:]
        var next = RuntimeOutput()
        for (name, shown) in scene.shown.sorted(by: { $0.key < $1.key }) {
            var targets = scene.displays
            if kind.isSurface {
                guard let spec = specs[name] else { continue }
                targets = spec.screen.select(targets, focused: shown.focused)
                next.surfaces[name] = spec
            }
            next.trees[name] = try Dictionary(uniqueKeysWithValues: targets.map { display in
                try (display.id, render(display, name, with: functions))
            })
        }
        return next
    }

    private func surfaces(_ functions: PluginFunctions) throws -> [String: SurfaceSpec] {
        let text = try invoke(functions.surfaces, .render, [stateText(for: nil)], [.jsParse, .render, .stringify])
        let json = try timed(.swiftParse) { try JSON.parse(text.toString() ?? "{}") }
        return try timed(.nodeParse) { try SurfaceSpec.parseAll(json, kind: kind) }
    }

    private func fail(_ reason: String) {
        teardown()
        deliver(self, .failed(reason))
    }

    private func teardown() {
        functions.map(unload)
        hub.unsubscribe(self)
        for cancel in timers.values {
            cancel()
        }
        timers = [:]
        for stop in stops {
            stop()
        }
        stops = []
        functions = nil
        replies.values.forEach { $0.reply(.failure("\(id) stopped before \($0.method) replied")) }
        replies = [:]
        ShaderCache.shared.drop(id)
    }

    var isRunning: Bool {
        functions != nil
    }

    func onStop(_ stop: @escaping () -> Void) {
        stops.append(stop)
    }

    func callBack(_ callback: JSValue, _ arguments: @autoclosure () -> [Any], _ trace: Trace, cause: EngineCause = .host) {
        guard isRunning else { return }
        entryTrace = trace.id
        do {
            try invoke(callback, cause, arguments(), [.handler])
            renderAll(trace)
        } catch {
            fail("\(error)")
        }
    }

    private func render(_ display: DisplayInfo, _ surface: String, with functions: PluginFunctions) throws -> Node? {
        let value = try invoke(functions.render, .render, [stateText(for: display, surface: surface)], [.jsParse, .render, .stringify])
        let json = try timed(.swiftParse) { () throws -> JSON in
            guard value.isString, let text = value.toString() else { throw RenderError("render returned nothing") }
            return try JSON.parse(text)
        }
        return try metrics.rendered(keeping: output.trees[surface]?[display.id].flatMap(\.self), of: "\(id)/\(kind.rawValue) \(surface)") {
            json == .null && kind == .barWidget
                ? nil : try timed(.nodeParse) { try Node.parse(json).resolvingPaths(against: bundle.directory.path, home: home) }
        }
    }

    private func stateText(for display: DisplayInfo?, surface: String? = nil) -> String {
        timed(.encode) { state.text(display: display, surface: surface) }
    }

    private func encode(_ json: JSON) -> String {
        timed(.encode) { json.text }
    }

    private func traced(_ trace: Trace) -> Trace {
        var trace = trace
        trace.timings.merge(timings)
        timings = Timings()
        return trace
    }
}

private extension PluginRuntime {
    func evaluate() throws -> PluginFunctions {
        let entry = try bundle.entryPoint(kind)
        let modules = try transpiler.modules(of: bundle, from: entry)
        guard let context = engine.makeContext() else { throw RenderError("no JavaScript context") }
        context.name = "\(id)"
        context.exceptionHandler = { [weak self] _, value in
            let message = value?.toString() ?? "unknown exception"
            self?.assumeIsolated { $0.exception = message }
        }
        let host = try check(in: context) { makeHost(in: context) }
        let declared = bundle.manifest.capabilities
        try check(in: context) {
            for capability in Capability.all where declared.contains(capability.name) {
                capability.install?(host, self)
            }
            return JSValue(undefinedIn: context)
        }
        context.setObject(host, forKeyedSubscript: "host" as NSString)
        try installTimers(in: context)
        try check(in: context) { context.evaluateScript(PluginScripts.textCodec)?.call(withArguments: []) }
        try check(in: context) { context.evaluateScript(PluginScripts.jsx)?.call(withArguments: []) }
        var factories: [String: JSValue] = [:]
        for module in modules {
            factories[module.path] = try check(in: context) {
                context.evaluateScript("(function (exports, require) {\(module.code)\n})", withSourceURL: module.url)
            }
        }
        let links = Dictionary(uniqueKeysWithValues: modules.map { ($0.path, $0.links) })
        let library: @convention(block) () -> JSValue? = { [engine] in
            do {
                return try engine.effect()
            } catch {
                let context = JSContext.current()
                context?.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
                return nil
            }
        }
        let loaded = try check(in: context) {
            context.evaluateScript(PluginScripts.modules)?.call(withArguments: [factories, links, entry, library, state.settings])
        }
        let exported: JSValue = loaded.atIndex(0)
        let effect: JSValue = loaded.atIndex(1)
        let wrappers = try check(in: context) {
            context.evaluateScript(PluginScripts.functions)?.call(withArguments: [exported, kind == .service, effect])
        }
        let functions = PluginFunctions(wrappers)
        self.functions = functions
        return functions
    }

    func unload(_ functions: PluginFunctions) {
        do {
            try invoke(functions.unload, .load, [])
        } catch {
            log("plugin \(id): unload failed: \(error)")
        }
    }

    @discardableResult
    func invoke(_ function: JSValue, _ cause: EngineCause, _ arguments: @autoclosure () -> [Any], _ stages: [Stage] = []) throws -> JSValue {
        var spent = Timings()
        defer { timings.merge(spent) }
        return try check(in: function.context, cause) { function.call(arguments(), timing: stages, into: &spent) }
    }

    func timed<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        var spent = Timings()
        defer { timings.merge(spent) }
        return try measure(stage, &spent, body)
    }
}

extension PluginRuntime {
    @discardableResult
    func check(in context: JSContext, _ cause: EngineCause = .load, _ body: () -> JSValue?) throws -> JSValue {
        exception = nil
        let started = TraceLog.isOn ? TraceLog.uptime() : 0
        defer { TraceLog.note(
            "entry",
            entryTrace,
            ["plugin": TraceLog.slot(slot), "cause": .string("\(cause)"), "ms": TraceLog.milliseconds(since: started)],
        ) }
        let result = try engine.run(id, in: context, cause, into: metrics, body)
        if let exception {
            throw RenderError(exception)
        }
        guard let result else { throw RenderError("script returned no value") }
        return result
    }
}
