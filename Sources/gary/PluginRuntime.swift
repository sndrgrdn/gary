import Foundation
import GaryCore
import GaryPrivate
import JavaScriptCore

struct Scene: Equatable {
    var displays: [DisplayInfo] = []
    var shown = false
    var focused: String?
}

struct RuntimeOutput: Equatable {
    var surface: SurfaceSpec?
    var trees: [String: Node] = [:]
}

enum SurfaceRequest: String {
    case show, hide, toggle
}

enum RuntimeEvent {
    case loaded(RuntimeOutput, Trace)
    case output(RuntimeOutput, Trace)
    case surface(SurfaceRequest, origin: CGRect?)
    case call(method: String, arguments: [String], reply: (Response) -> Void)
    case failed(String)
}

private final class Watchdog {
    var fired = false
}

final class PluginRuntime: Subscriber {
    static let timeLimit = 0.1

    let bundle: PluginBundle
    let kind: PluginKind
    private let hub: StateHub
    private let settings: JSON
    private let deliver: (PluginRuntime, RuntimeEvent) -> Void
    let queue: DispatchQueue
    private let watchdog = Watchdog()
    private var functions: PluginFunctions?
    private var exception: String?
    private var state: [Topic: JSON] = [:]
    private var theme: JSON
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var stops: [() -> Void] = []
    private var nextTimer = 1
    let initialScene: Scene
    private var scene: Scene
    private var output = RuntimeOutput()
    private var origin: CGRect?

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
        deliver: @escaping (PluginRuntime, RuntimeEvent) -> Void,
    ) {
        self.bundle = bundle
        self.kind = kind
        self.scene = scene
        initialScene = scene
        self.settings = settings
        self.theme = theme
        self.hub = hub
        self.deliver = deliver
        queue = DispatchQueue(label: "gary.plugin.\(bundle.manifest.id)", qos: .userInitiated)
    }

    func load(_ trace: Trace) {
        queue.async { [self] in
            state = hub.subscribe(self, to: bundle.manifest.subscribes)
            do {
                let functions = try evaluate()
                for (topic, value) in state.sorted(by: { $0.key.description < $1.key.description }) {
                    try announce(topic, value, to: functions)
                }
                output = try renderOutput(functions)
                deliver(self, .loaded(output, trace))
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
            self.theme = theme
            renderAll(trace)
        }
    }

    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        queue.async { [self] in
            state[topic] = value
            guard let functions else { return }
            do {
                try announce(topic, value, to: functions)
                renderAll(trace)
            } catch {
                fail("\(error)")
            }
        }
    }

    private func announce(_ topic: Topic, _ value: JSON, to functions: PluginFunctions) throws {
        try invoke(functions.dispatch, ["onTopic", JSON.array([.string(topic.description), value]).text, stateText(for: nil)])
    }

    func perform(_ action: String, _ payload: JSON, origin: CGRect? = nil) {
        dispatch("onAction", [.string(action), payload], Trace("action"), origin: origin)
    }

    func key(_ key: String, unhandled: @escaping () -> Void) {
        dispatch("onKey", [.string(key)], Trace("key"), unhandled: unhandled)
    }

    func scroll(_ event: JSON) {
        dispatch("onScroll", [event], Trace("scroll"))
    }

    func hotkey(_ id: String) {
        dispatch("onHotkey", [.string(id)], Trace("hotkey"))
    }

    func mediaKey(_ event: JSON) {
        dispatch("onMediaKey", [event], Trace("mediakey"))
    }

    private func dispatch(_ handler: String, _ arguments: [JSON], _ trace: Trace, origin: CGRect? = nil, unhandled: (() -> Void)? = nil) {
        queue.async { [self] in
            guard let functions else { return }
            self.origin = origin
            defer { self.origin = nil }
            do {
                let handled = try invoke(functions.dispatch, [handler, JSON.array(arguments).text, stateText(for: nil)])
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

    func call(_ method: String, _ arguments: [String], reply: @escaping (Response) -> Void) {
        queue.async { [self] in
            guard let functions else { return reply(.failure("\(id) is not running")) }
            let done: @convention(block) (Bool, String) -> Void = { ok, text in reply(ok ? .ok(text) : .failure(text)) }
            do {
                try invoke(functions.call, [method, JSON.array(arguments.map(JSON.string)).text, done])
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
            guard always || next != output else { return }
            output = next
            deliver(self, .output(next, trace))
        } catch {
            fail("\(error)")
        }
    }

    private func renderOutput(_ functions: PluginFunctions) throws -> RuntimeOutput {
        guard scene.shown else { return RuntimeOutput() }
        var next = RuntimeOutput()
        var targets = scene.displays
        if kind.isSurface {
            let text = try invoke(functions.surface, [stateText(for: nil)]).toString() ?? "null"
            let surface = try SurfaceSpec.parse(JSON.parse(text), kind: kind)
            targets = surface.screen.select(targets, focused: scene.focused)
            next.surface = surface
        }
        for display in targets {
            next.trees[display.id] = try render(display, with: functions)
        }
        return next
    }

    private func fail(_ reason: String) {
        teardown()
        deliver(self, .failed(reason))
    }

    private func teardown() {
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
    }

    var isRunning: Bool {
        functions != nil
    }

    func onStop(_ stop: @escaping () -> Void) {
        stops.append(stop)
    }

    func callBack(_ callback: JSValue, _ arguments: [Any], _ trace: Trace) {
        guard isRunning else { return }
        do {
            try invoke(callback, arguments)
            renderAll(trace)
        } catch {
            fail("\(error)")
        }
    }

    private func render(_ display: DisplayInfo, with functions: PluginFunctions) throws -> Node {
        let text = try invoke(functions.render, [stateText(for: display)])
        guard text.isString, let json = text.toString() else { throw RenderError("render returned nothing") }
        return try Node.parse(Data(json.utf8)).resolvingImages(against: bundle.directory)
    }

    private func stateText(for display: DisplayInfo?) -> String {
        var fields = Dictionary(uniqueKeysWithValues: state.map { ($0.key.description, $0.value) })
        fields["settings"] = settings
        fields["theme"] = theme
        fields["display"] = display?.json
        return JSON.object(fields).text
    }
}

private extension PluginRuntime {
    func evaluate() throws -> PluginFunctions {
        let url = try bundle.entryPoint(kind)
        var source = try String(contentsOf: url, encoding: .utf8)
        if url.pathExtension == "ts" {
            source = try TypeScript.shared.strip(source, file: url.lastPathComponent)
        }
        guard let context = JSContext() else { throw RenderError("no JavaScript context") }
        context.name = "\(id)"
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() ?? "unknown exception" }
        if !gary_script_time_limit(context.jsGlobalContextRef, Self.timeLimit, { _, info in
            if let info {
                Unmanaged<Watchdog>.fromOpaque(info).takeUnretainedValue().fired = true
            }
            return true
        }, Unmanaged.passUnretained(watchdog).toOpaque()) {
            log("plugin \(id): no script time limit on this system")
        }
        let host = try makeHost(in: context)
        for capability in Capability.all where bundle.manifest.uses.contains(capability.name) {
            capability.install?(host, self)
        }
        context.setObject(host, forKeyedSubscript: "host" as NSString)
        try installTimers(in: context)
        context.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
        try check { context.evaluateScript(source, withSourceURL: url) }
        let wrappers = try check { context.evaluateScript(PluginScripts.functions)?.call(withArguments: [kind == .service]) }
        let functions = PluginFunctions(wrappers)
        self.functions = functions
        return functions
    }

    func installTimers(in context: JSContext) throws {
        let add: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] callback, milliseconds, repeats in
            self?.addTimer(callback, milliseconds: milliseconds, repeats: repeats) ?? 0
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        try check { context.evaluateScript(PluginScripts.timers)?.call(withArguments: [add, clear]) }
    }

    func makeHost(in context: JSContext) throws -> JSValue {
        let id = id
        let logBlock: @convention(block) (String) -> Void = { message in log("plugin \(id): \(message)") }
        let storageURL = Paths.storage.appending(path: "\(id).json")
        let read: @convention(block) () -> String? = { try? String(contentsOf: storageURL, encoding: .utf8) }
        let write: @convention(block) (String) -> Void = { text in
            do {
                try FileManager.default.createDirectory(at: Paths.storage, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: storageURL, options: .atomic)
            } catch {
                log("plugin \(id): storage not saved: \(error)")
            }
        }
        let publishBlock: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let text = value.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value]).toString(),
                  let json = try? JSON.parse(text) else { return }
            hub.publish(.plugin(id), json, Trace("publish"))
        }
        let surfaceBlocks = [SurfaceRequest.show, .hide, .toggle].map { request in
            { [weak self] in
                guard let self else { return }
                deliver(self, .surface(request, origin: origin))
            } as @convention(block) () -> Void
        }
        let callBlock: @convention(block) (String, [String], JSValue, JSValue) -> Void = { [weak self] method, arguments, resolve, reject in
            guard let self else { return }
            deliver(self, .call(method: method, arguments: arguments) { [weak self] response in
                self?.queue.async {
                    switch response {
                    case let .ok(text): self?.callBack(resolve, [text], Trace("host.call"))
                    case let .failure(message): self?.callBack(reject, [message], Trace("host.call"))
                    }
                }
            })
        }
        return try check {
            context.evaluateScript(PluginScripts.host)?.call(withArguments: [logBlock, read, write, publishBlock] + surfaceBlocks + [callBlock])
        }
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
    func invoke(_ function: JSValue, _ arguments: [Any]) throws -> JSValue {
        try check { function.call(withArguments: arguments) }
    }

    @discardableResult
    func check(_ body: () -> JSValue?) throws -> JSValue {
        exception = nil
        watchdog.fired = false
        let result = body()
        if watchdog.fired {
            throw RenderError("stopped after running longer than \(Int(Self.timeLimit * 1000)) ms")
        }
        if let exception {
            throw RenderError(exception)
        }
        guard let result else { throw RenderError("script returned no value") }
        return result
    }
}

struct RenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
