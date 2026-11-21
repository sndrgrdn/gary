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
    case surface(SurfaceRequest)
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
    private var context: JSContext?
    private var functions: (render: JSValue, dispatch: JSValue, call: JSValue, surface: JSValue)?
    private var exception: String?
    private var state: [Topic: JSON] = [:]
    private var theme: JSON
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var stops: [() -> Void] = []
    private var nextTimer = 1
    let initialScene: Scene
    private var scene: Scene
    private var output = RuntimeOutput()

    var id: PluginID { bundle.manifest.id }

    init(bundle: PluginBundle, kind: PluginKind, scene: Scene, settings: JSON, theme: JSON, hub: StateHub,
         deliver: @escaping (PluginRuntime, RuntimeEvent) -> Void) {
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
                try evaluate()
                for (topic, value) in state.sorted(by: { $0.key.description < $1.key.description }) { try announce(topic, value) }
                output = try renderOutput()
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
            guard functions != nil else { return }
            do {
                try announce(topic, value)
                renderAll(trace)
            } catch {
                fail("\(error)")
            }
        }
    }

    private func announce(_ topic: Topic, _ value: JSON) throws {
        try invoke(functions!.dispatch, ["onTopic", JSON.array([.string(topic.description), value]).text, stateText(for: nil)])
    }

    func perform(_ action: String, _ payload: JSON) {
        dispatch("onAction", [.string(action), payload], Trace("action"))
    }

    func key(_ key: String) {
        dispatch("onKey", [.string(key)], Trace("key"))
    }

    func hotkey(_ id: String) {
        dispatch("onHotkey", [.string(id)], Trace("hotkey"))
    }

    func mediaKey(_ event: JSON) {
        dispatch("onMediaKey", [event], Trace("mediakey"))
    }

    private func dispatch(_ handler: String, _ arguments: [JSON], _ trace: Trace) {
        queue.async { [self] in
            guard let functions else { return }
            do {
                try invoke(functions.dispatch, [handler, JSON.array(arguments).text, stateText(for: nil)])
                renderAll(trace)
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
        guard functions != nil else { return }
        do {
            let next = try renderOutput()
            guard always || next != output else { return }
            output = next
            deliver(self, .output(next, trace))
        } catch {
            fail("\(error)")
        }
    }

    private func renderOutput() throws -> RuntimeOutput {
        guard scene.shown else { return RuntimeOutput() }
        var next = RuntimeOutput()
        var targets = scene.displays
        if kind.isSurface {
            let text = try invoke(functions!.surface, [stateText(for: nil)]).toString() ?? "null"
            let surface = try SurfaceSpec.parse(try JSON.parse(text), kind: kind)
            targets = surface.screen.select(targets, focused: scene.focused)
            next.surface = surface
        }
        for display in targets { next.trees[display.id] = try render(display) }
        return next
    }

    private func fail(_ reason: String) {
        teardown()
        deliver(self, .failed(reason))
    }

    private func teardown() {
        hub.unsubscribe(self)
        for timer in timers.values { timer.cancel() }
        timers = [:]
        for stop in stops { stop() }
        stops = []
        functions = nil
        context = nil
    }

    private func addTimer(_ callback: JSValue, milliseconds: Double, repeats: Bool) -> Int {
        let id = nextTimer
        nextTimer += 1
        let interval = max(repeats ? 10 : 0, milliseconds.isFinite ? milliseconds : 0) / 1000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: repeats ? interval : .infinity, leeway: .milliseconds(max(1, min(100, Int(interval * 100)))))
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            if !repeats { timers.removeValue(forKey: id)?.cancel() }
            callBack(callback, [], Trace("timer"))
        }
        timers[id] = timer
        timer.resume()
        return id
    }

    var isRunning: Bool { functions != nil }

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

    private func evaluate() throws {
        let url = try bundle.entryPoint(kind)
        var source = try String(contentsOf: url, encoding: .utf8)
        if url.pathExtension == "ts" { source = try TypeScript.shared.strip(source, file: url.lastPathComponent) }
        let context = JSContext()!
        context.name = "\(id)"
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() ?? "unknown exception" }
        if !gary_script_time_limit(context.jsGlobalContextRef, Self.timeLimit, { _, info in
            Unmanaged<Watchdog>.fromOpaque(info!).takeUnretainedValue().fired = true
            return true
        }, Unmanaged.passUnretained(watchdog).toOpaque()) {
            log("plugin \(id): no script time limit on this system")
        }
        let host = makeHost(in: context)
        for capability in Capability.all where bundle.manifest.uses.contains(capability.name) { capability.install?(host, self) }
        context.setObject(host, forKeyedSubscript: "host" as NSString)
        installTimers(in: context)
        context.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
        try check { context.evaluateScript(source, withSourceURL: url) }
        let wrappers = try check { context.evaluateScript("""
        (function (m, headless) {
          var e = function () { return m.exports; };
          if (!headless && typeof e().render !== "function") throw new Error("module.exports.render is not a function");
          return [
            function (state) { return JSON.stringify(e().render(JSON.parse(state))); },
            function (name, args, state) {
              var f = e()[name];
              if (typeof f === "function") f.apply(e(), JSON.parse(args).concat([JSON.parse(state)]));
            },
            function (method, args, done) {
              var f = e().methods && e().methods[method];
              if (typeof f !== "function") throw new Error("no method " + method);
              var r = f.apply(null, JSON.parse(args));
              var text = function (v) { return v === undefined ? "" : JSON.stringify(v); };
              if (!r || typeof r.then !== "function") return done(true, text(r));
              r.then(function (v) { done(true, text(v)); }, function (x) { done(false, x instanceof Error ? x.message : String(x)); });
            },
            function (state) {
              var s = e().surface;
              if (typeof s === "function") s = s(JSON.parse(state));
              return JSON.stringify(s === undefined ? null : s);
            }
          ];
        })
        """)?.call(withArguments: [context.objectForKeyedSubscript("module")!, kind == .service]) }
        self.context = context
        functions = (wrappers.atIndex(0), wrappers.atIndex(1), wrappers.atIndex(2), wrappers.atIndex(3))
    }

    private func installTimers(in context: JSContext) {
        let add: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] callback, milliseconds, repeats in
            self?.addTimer(callback, milliseconds: milliseconds, repeats: repeats) ?? 0
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        context.evaluateScript("""
        (function (g, add, clear) {
          function timer(repeats) {
            return function (f, ms) {
              var args = Array.prototype.slice.call(arguments, 2);
              if (typeof f !== "function") throw new TypeError("timer callback must be a function");
              return add(function () { f.apply(null, args); }, Number(ms) || 0, repeats);
            };
          }
          g.setTimeout = timer(false);
          g.setInterval = timer(true);
          g.clearTimeout = g.clearInterval = function (id) { if (typeof id === "number") clear(id); };
        })
        """).call(withArguments: [context.globalObject!, add, clear])
    }

    private func makeHost(in context: JSContext) -> JSValue {
        let host = JSValue(newObjectIn: context)!
        let id = self.id
        let logBlock: @convention(block) (String) -> Void = { message in log("plugin \(id): \(message)") }
        host.setObject(logBlock, forKeyedSubscript: "log" as NSString)
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
        host.setObject(context.evaluateScript("""
        (function (read, write) {
          var data = null;
          function load() {
            if (data !== null) return;
            var text = read();
            try { data = text ? JSON.parse(text) : {}; } catch (e) { data = {}; }
          }
          return {
            get: function (key) { load(); return data[key]; },
            set: function (key, value) {
              load();
              if (value === undefined) delete data[key]; else data[key] = JSON.parse(JSON.stringify(value));
              write(JSON.stringify(data));
            }
          };
        })
        """).call(withArguments: [read, write]), forKeyedSubscript: "storage" as NSString)
        let publishBlock: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let text = value.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value]).toString(),
                  let json = try? JSON.parse(text) else { return }
            hub.publish(.plugin(id), json, Trace("publish"))
        }
        host.setObject(publishBlock, forKeyedSubscript: "publish" as NSString)
        for request in [SurfaceRequest.show, .hide, .toggle] {
            let block: @convention(block) () -> Void = { [weak self] in
                guard let self else { return }
                deliver(self, .surface(request))
            }
            host.setObject(block, forKeyedSubscript: request.rawValue as NSString)
        }
        return host
    }

    private func render(_ display: DisplayInfo) throws -> Node {
        let text = try invoke(functions!.render, [stateText(for: display)])
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

    @discardableResult
    private func invoke(_ function: JSValue, _ arguments: [Any]) throws -> JSValue {
        try check { function.call(withArguments: arguments) }
    }

    @discardableResult
    private func check(_ body: () -> JSValue?) throws -> JSValue {
        exception = nil
        watchdog.fired = false
        let result = body()
        if watchdog.fired { throw RenderError("stopped after running longer than \(Int(Self.timeLimit * 1000)) ms") }
        if let exception { throw RenderError(exception) }
        guard let result else { throw RenderError("script returned no value") }
        return result
    }
}

struct RenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
