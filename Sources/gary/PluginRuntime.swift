import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

final nonisolated class PluginRuntime: Subscriber, @unchecked Sendable {
    let bundle: PluginBundle
    let kind: PluginKind
    let hub: StateHub
    let deliver: @Sendable (PluginRuntime, RuntimeEvent) -> Void
    let queue: DispatchQueue
    private let engine: PluginEngine
    private let transpiler: Transpiler
    private var functions: PluginFunctions?
    private var exception: String?
    private var state: StateText
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var stops: [() -> Void] = []
    private var nextTimer = 1
    let initialScene: Scene
    private var scene: Scene
    private var output = RuntimeOutput()
    private(set) var origin: CGRect?
    private var timings = Timings()

    var id: PluginID {
        bundle.manifest.id
    }

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
        queue = DispatchQueue(label: "gary.plugin.\(bundle.manifest.id)", qos: .userInitiated, target: engine.queue)
    }

    func load(_ trace: Trace) {
        queue.async { [self] in
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
    }

    func stop() {
        queue.async { [self] in teardown() }
    }

    func setScene(_ scene: Scene, _ trace: Trace) {
        queue.async { [self] in
            self.scene = scene
            renderAll(trace, always: true)
        }
    }

    func setTheme(_ theme: JSON, _ trace: Trace) {
        queue.async { [self] in
            state.setTheme(theme)
            renderAll(trace)
        }
    }

    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        queue.async { [self] in
            let text = timed(.encode) { state.set(topic, value) }
            guard let functions else { return }
            do {
                try announce(topic, text, to: functions)
                renderAll(trace)
            } catch {
                fail("\(error)")
            }
        }
    }

    private func announce(_ topic: Topic, _ text: String, to functions: PluginFunctions) throws {
        let arguments = "[{\"topic\":\(encode(.string(topic.description))),\"value\":\(text)}]"
        try invoke(functions.dispatch, ["onTopic", arguments, stateText(for: nil)], [.jsParse, .handler])
    }

    func perform(_ action: String, _ payload: JSON, origin: CGRect? = nil) {
        dispatch("onAction", [.string(action), payload], Trace("action"), origin: origin)
    }

    func key(_ key: String, unhandled: @escaping @MainActor @Sendable () -> Void) {
        dispatch("onKey", [.string(key)], Trace("key"), unhandled: unhandled)
    }

    func scroll(_ event: JSON, action: String? = nil, origin: CGRect? = nil) {
        var fields = event.object ?? [:]
        fields["action"] = action.map(JSON.string)
        dispatch("onScroll", [.object(fields)], Trace("scroll"), origin: origin)
    }

    func hotkey(_ id: String) {
        dispatch("onHotkey", [.string(id)], Trace("hotkey"))
    }

    func mediaKey(_ event: JSON) {
        dispatch("onMediaKey", [event], Trace("mediakey"))
    }

    private func dispatch(
        _ handler: String,
        _ arguments: [JSON],
        _ trace: Trace,
        origin: CGRect? = nil,
        unhandled: (@MainActor @Sendable () -> Void)? = nil,
    ) {
        queue.async { [self] in
            guard let functions else { return }
            self.origin = origin
            defer { self.origin = nil }
            do {
                let handled = try invoke(functions.dispatch, [handler, encode(JSON.array(arguments)), stateText(for: nil)], [.jsParse, .handler])
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
    }

    func call(_ method: String, _ arguments: [String], reply: @escaping @Sendable (Response) -> Void) {
        queue.async { [self] in
            guard let functions else { return reply(.failure("\(id) is not running")) }
            let done: @convention(block) (Bool, String) -> Void = { ok, text in reply(ok ? .ok(text) : .failure(text)) }
            do {
                try invoke(functions.call, [method, encode(JSON.array(arguments.map(JSON.string))), done], [.jsParse, .handler])
                renderAll(Trace("call"))
            } catch {
                reply(.failure("\(error)"))
            }
        }
    }

    private func renderAll(_ trace: Trace, always: Bool = false) {
        guard let functions else { return }
        do {
            let next = try renderOutput(functions)
            let changed = timed(.compare) { next != output }
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
        let text = try invoke(functions.surfaces, [stateText(for: nil)], [.jsParse, .render, .stringify])
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
        for timer in timers.values {
            timer.cancel()
        }
        timers = [:]
        for stop in stops {
            stop()
        }
        stops = []
        functions = nil
        ShaderCache.shared.drop(id)
    }

    var isRunning: Bool {
        functions != nil
    }

    func onStop(_ stop: @escaping () -> Void) {
        stops.append(stop)
    }

    func callBack(_ callback: JSValue, _ arguments: @autoclosure () -> [Any], _ trace: Trace) {
        guard isRunning else { return }
        do {
            try invoke(callback, arguments(), [.handler])
            renderAll(trace)
        } catch {
            fail("\(error)")
        }
    }

    private func render(_ display: DisplayInfo, _ surface: String, with functions: PluginFunctions) throws -> Node? {
        let value = try invoke(functions.render, [stateText(for: display, surface: surface)], [.jsParse, .render, .stringify])
        let json = try timed(.swiftParse) { () throws -> JSON in
            guard value.isString, let text = value.toString() else { throw RenderError("render returned nothing") }
            return try JSON.parse(text)
        }
        if json == .null, kind == .barWidget {
            return nil
        }
        return try timed(.nodeParse) { try Node.parse(json).resolvingPaths(against: bundle.directory) }
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

private nonisolated extension PluginRuntime {
    func evaluate() throws -> PluginFunctions {
        let entry = try bundle.entryPoint(kind)
        let modules = try transpiler.modules(of: bundle, from: entry)
        guard let context = engine.makeContext() else { throw RenderError("no JavaScript context") }
        context.name = "\(id)"
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() ?? "unknown exception" }
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
            try invoke(functions.unload, [])
        } catch {
            log("plugin \(id): unload failed: \(error)")
        }
    }

    func installTimers(in context: JSContext) throws {
        let add: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] callback, milliseconds, repeats in
            self?.addTimer(callback, milliseconds: milliseconds, repeats: repeats) ?? 0
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        try check(in: context) { context.evaluateScript(PluginScripts.timers)?.call(withArguments: [add, clear]) }
    }

    func addTimer(_ callback: JSValue, milliseconds: Double, repeats: Bool) -> Int {
        let id = nextTimer
        nextTimer += 1
        let interval = max(repeats ? 10 : 0, milliseconds.isFinite ? milliseconds : 0) / 1000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: repeats ? interval : .infinity,
            leeway: .milliseconds(max(1, min(100, Int(interval * 100)))),
        )
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            if !repeats {
                timers.removeValue(forKey: id)?.cancel()
            }
            callBack(callback, [], Trace("timer"))
        }
        timers[id] = timer
        timer.resume()
        return id
    }

    @discardableResult
    func invoke(_ function: JSValue, _ arguments: @autoclosure () -> [Any], _ stages: [Stage] = []) throws -> JSValue {
        var spent = Timings()
        defer { timings.merge(spent) }
        return try check(in: function.context) { function.call(arguments(), timing: stages, into: &spent) }
    }

    func timed<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        var spent = Timings()
        defer { timings.merge(spent) }
        return try measure(stage, &spent, body)
    }

    @discardableResult
    func check(in context: JSContext, _ body: () -> JSValue?) throws -> JSValue {
        exception = nil
        let result = try engine.run(id, in: context, body)
        if let exception {
            throw RenderError(exception)
        }
        guard let result else { throw RenderError("script returned no value") }
        return result
    }
}

nonisolated struct RenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
