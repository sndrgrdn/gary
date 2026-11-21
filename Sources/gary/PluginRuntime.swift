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
    private let queue: DispatchQueue
    private let watchdog = Watchdog()
    private var context: JSContext?
    private var functions: (render: JSValue, dispatch: JSValue, call: JSValue, surface: JSValue)?
    private var exception: String?
    private var state: [Topic: JSON] = [:]
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
        functions = nil
        context = nil
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

    private func makeHost(in context: JSContext) -> JSValue {
        let host = JSValue(newObjectIn: context)!
        let id = self.id
        let logBlock: @convention(block) (String) -> Void = { message in log("plugin \(id): \(message)") }
        host.setObject(logBlock, forKeyedSubscript: "log" as NSString)
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
            self?.queue.async {
                guard let self, self.functions != nil else { return }
                do {
                    try self.invoke(callback, [result])
                    self.renderAll(Trace("exec"))
                } catch {
                    self.fail("\(error)")
                }
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
