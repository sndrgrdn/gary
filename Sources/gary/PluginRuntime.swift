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

private final class FileWatch {
    let path: String
    let callback: JSValue
    var source: DispatchSourceFileSystemObject?
    var pending: DispatchWorkItem?

    init(path: String, callback: JSValue) {
        self.path = path
        self.callback = callback
    }
}

private let fetchSession = URLSession(configuration: .ephemeral)

final class PluginRuntime: Subscriber {
    static let timeLimit = 0.1

    let bundle: PluginBundle
    let kind: PluginKind
    private let hub: StateHub
    private let settings: JSON
    private let deliver: (PluginRuntime, RuntimeEvent) -> Void
    private let queue: DispatchQueue
    private let watchdog = Watchdog()
    private var context: JSContext?
    private var functions: (render: JSValue, dispatch: JSValue, call: JSValue, surface: JSValue)?
    private var exception: String?
    private var state: [Topic: JSON] = [:]
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var watches: [FileWatch] = []
    private var nextTimer = 1
    let initialScene: Scene
    private var scene: Scene
    private var output = RuntimeOutput()

    var id: PluginID { bundle.manifest.id }

    init(bundle: PluginBundle, kind: PluginKind, scene: Scene, settings: JSON, hub: StateHub, deliver: @escaping (PluginRuntime, RuntimeEvent) -> Void) {
        self.bundle = bundle
        self.kind = kind
        self.scene = scene
        initialScene = scene
        self.settings = settings
        self.hub = hub
        self.deliver = deliver
        queue = DispatchQueue(label: "gary.plugin.\(bundle.manifest.id)", qos: .userInitiated)
    }

    func load(_ trace: Trace) {
        queue.async { [self] in
            state = hub.subscribe(self, to: bundle.manifest.subscribes)
            do {
                try evaluate()
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

    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        queue.async { [self] in
            state[topic] = value
            renderAll(trace)
        }
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

    func call(_ method: String, _ arguments: [String]) -> Response {
        queue.sync {
            guard let functions else { return .failure("\(id) is not running") }
            do {
                let result = try invoke(functions.call, [method, JSON.array(arguments.map(JSON.string)).text]).toString() ?? ""
                renderAll(Trace("call"))
                return .ok(result)
            } catch {
                return .failure("\(error)")
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
        for watch in watches {
            watch.source?.cancel()
            watch.pending?.cancel()
        }
        watches = []
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
            guard let self, functions != nil else { return }
            if !repeats { timers.removeValue(forKey: id)?.cancel() }
            callBack(callback, [], Trace("timer"))
        }
        timers[id] = timer
        timer.resume()
        return id
    }

    private func callBack(_ callback: JSValue, _ arguments: [Any], _ trace: Trace) {
        do {
            try invoke(callback, arguments)
            renderAll(trace)
        } catch {
            fail("\(error)")
        }
    }

    private func fetch(_ url: URL, _ resolve: JSValue, _ reject: JSValue) {
        fetchSession.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { [weak self] data, response, error in
            self?.queue.async { [weak self] in
                guard let self, functions != nil else { return }
                if let error {
                    callBack(reject, [JSValue(newErrorFromMessage: "fetch failed: \(error.localizedDescription)", in: resolve.context)!], Trace("fetch"))
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    callBack(resolve, [["status": status, "text": String(decoding: data ?? Data(), as: UTF8.self)]], Trace("fetch"))
                }
            }
        }.resume()
    }

    private func arm(_ watch: FileWatch, attempts: Int) {
        let descriptor = open(watch.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if attempts > 0 {
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak watch] in
                    guard let self, let watch, functions != nil else { return }
                    arm(watch, attempts: attempts - 1)
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self, weak watch, weak source] in
            guard let self, let watch, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                arm(watch, attempts: 10)
            }
            watch.pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak watch] in
                guard let self, let watch, functions != nil else { return }
                let text = try? String(contentsOfFile: watch.path, encoding: .utf8)
                callBack(watch.callback, [text ?? NSNull()], Trace("file"))
            }
            watch.pending = work
            queue.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        watch.source = source
        source.resume()
    }

    private func evaluate() throws {
        let url = try bundle.entryPoint(kind)
        let source = try String(contentsOf: url, encoding: .utf8)
        let context = JSContext()!
        context.name = "\(id)"
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() ?? "unknown exception" }
        if !gary_script_time_limit(context.jsGlobalContextRef, Self.timeLimit, { _, info in
            Unmanaged<Watchdog>.fromOpaque(info!).takeUnretainedValue().fired = true
            return true
        }, Unmanaged.passUnretained(watchdog).toOpaque()) {
            log("plugin \(id): no script time limit on this system")
        }
        context.setObject(makeHost(in: context), forKeyedSubscript: "host" as NSString)
        installTimers(in: context)
        if bundle.manifest.uses.contains(.network) { installFetch(in: context) }
        context.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
        try check { context.evaluateScript(source, withSourceURL: url) }
        let wrappers = try check { context.evaluateScript("""
        (function (m) {
          var e = function () { return m.exports; };
          if (typeof e().render !== "function") throw new Error("module.exports.render is not a function");
          return [
            function (state) { return JSON.stringify(e().render(JSON.parse(state))); },
            function (name, args, state) {
              var f = e()[name];
              if (typeof f === "function") f.apply(e(), JSON.parse(args).concat([JSON.parse(state)]));
            },
            function (method, args) {
              var f = e().methods && e().methods[method];
              if (typeof f !== "function") throw new Error("no method " + method);
              var r = f.apply(null, JSON.parse(args));
              return r === undefined ? "" : typeof r === "string" ? r : JSON.stringify(r);
            },
            function (state) {
              var s = e().surface;
              if (typeof s === "function") s = s(JSON.parse(state));
              return JSON.stringify(s === undefined ? null : s);
            }
          ];
        })(module)
        """) }
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

    private func installFetch(in context: JSContext) {
        let fetch: @convention(block) (String) -> JSValue = { [weak self] address in
            let context = JSContext.current()!
            return JSValue(newPromiseIn: context) { resolve, reject in
                guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else {
                    reject?.call(withArguments: [JSValue(newErrorFromMessage: "fetch takes an http or https URL", in: context)!])
                    return
                }
                self?.fetch(url, resolve!, reject!)
            }
        }
        context.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
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
        if bundle.manifest.uses.contains(.files) {
            let readFile: @convention(block) (String) -> String? = { path in
                let expanded = (path as NSString).expandingTildeInPath
                guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                    let context = JSContext.current()!
                    context.exception = JSValue(newErrorFromMessage: "cannot read \(path)", in: context)
                    return nil
                }
                return text
            }
            host.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
            let watchFile: @convention(block) (String, JSValue) -> Void = { [weak self] path, callback in
                guard let self, callback.isObject else { return }
                let watch = FileWatch(path: (path as NSString).expandingTildeInPath, callback: callback)
                watches.append(watch)
                arm(watch, attempts: 10)
            }
            host.setObject(watchFile, forKeyedSubscript: "watchFile" as NSString)
        }
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
        if bundle.manifest.uses.contains(.exec) {
            let execBlock: @convention(block) (JSValue, JSValue) -> Void = { [weak self] argv, callback in
                guard let argv = argv.toArray() as? [String], !argv.isEmpty, callback.isObject else {
                    let context = JSContext.current()!
                    context.exception = JSValue(newErrorFromMessage: "host.exec takes an array of strings and a callback", in: context)
                    return
                }
                self?.exec(argv, callback)
            }
            host.setObject(execBlock, forKeyedSubscript: "exec" as NSString)
        }
        return host
    }

    private func exec(_ argv: [String], _ callback: JSValue) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runProcess(argv)
            self?.queue.async { [weak self] in
                guard let self, functions != nil else { return }
                callBack(callback, [result], Trace("exec"))
            }
        }
    }

    private func render(_ display: DisplayInfo) throws -> Node {
        let text = try invoke(functions!.render, [stateText(for: display)])
        guard text.isString, let json = text.toString() else { throw RenderError("render returned nothing") }
        return try Node.parse(Data(json.utf8))
    }

    private func stateText(for display: DisplayInfo?) -> String {
        var fields = Dictionary(uniqueKeysWithValues: state.map { ($0.key.description, $0.value) })
        fields["settings"] = settings
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

private func runProcess(_ argv: [String]) -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["--"] + argv
    let output = Pipe(), errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return ["status": -1, "stdout": "", "stderr": "\(error)"]
    }
    var errorData = Data()
    let reading = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: reading) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    reading.wait()
    process.waitUntilExit()
    return [
        "status": Int(process.terminationStatus),
        "stdout": String(decoding: outputData, as: UTF8.self),
        "stderr": String(decoding: errorData, as: UTF8.self),
    ]
}

struct RenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
