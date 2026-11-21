import Foundation
import GaryCore
import GaryPrivate
import JavaScriptCore

struct DisplayInfo: Hashable {
    let id: String
    let notched: Bool
}

enum Target: Hashable, CustomStringConvertible {
    case bar(DisplayInfo)
    case panel

    var description: String {
        switch self {
        case .bar(let display): return "bar:\(display.id)"
        case .panel: return "panel"
        }
    }
}

enum RuntimeEvent {
    case loaded([Target: Node], Trace)
    case tree(Target, Node, Trace)
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
    private var functions: (render: JSValue, action: JSValue, call: JSValue)?
    private var exception: String?
    private var state: [Topic: JSON] = [:]
    private var targets: [Target]
    private var trees: [Target: Node] = [:]

    var id: PluginID { bundle.manifest.id }

    init(bundle: PluginBundle, kind: PluginKind, targets: [Target], settings: JSON, hub: StateHub, deliver: @escaping (PluginRuntime, RuntimeEvent) -> Void) {
        self.bundle = bundle
        self.kind = kind
        self.targets = targets
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
                var rendered: [Target: Node] = [:]
                for target in targets { rendered[target] = try render(target) }
                trees = rendered
                deliver(self, .loaded(rendered, trace))
            } catch {
                teardown()
                deliver(self, .failed("\(error)"))
            }
        }
    }

    func stop() {
        queue.async { [self] in teardown() }
    }

    func setTargets(_ targets: [Target], _ trace: Trace) {
        queue.async { [self] in
            self.targets = targets
            trees = [:]
            renderAll(trace)
        }
    }

    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        queue.async { [self] in
            state[topic] = value
            renderAll(trace)
        }
    }

    func perform(_ action: String) {
        queue.async { [self] in
            guard let functions else { return }
            do {
                try invoke(functions.action, [action, stateText(for: targets.first)])
                renderAll(Trace("action"))
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

    private func renderAll(_ trace: Trace) {
        guard functions != nil else { return }
        do {
            for target in targets {
                let tree = try render(target)
                guard trees[target] != tree else { continue }
                trees[target] = tree
                deliver(self, .tree(target, tree, trace))
            }
        } catch {
            fail("\(error)")
        }
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
            function (action, state) { if (typeof e().onAction === "function") e().onAction(action, JSON.parse(state)); },
            function (method, args) {
              var f = e().methods && e().methods[method];
              if (typeof f !== "function") throw new Error("no method " + method);
              var r = f.apply(null, JSON.parse(args));
              return r === undefined ? "" : typeof r === "string" ? r : JSON.stringify(r);
            }
          ];
        })(module)
        """) }
        self.context = context
        functions = (wrappers.atIndex(0), wrappers.atIndex(1), wrappers.atIndex(2))
    }

    private func makeHost(in context: JSContext) -> JSValue {
        let host = JSValue(newObjectIn: context)!
        let id = self.id
        let logBlock: @convention(block) (String) -> Void = { message in log("plugin \(id): \(message)") }
        host.setObject(logBlock, forKeyedSubscript: "log" as NSString)
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

    private func render(_ target: Target) throws -> Node {
        let text = try invoke(functions!.render, [stateText(for: target)])
        guard text.isString, let json = text.toString() else { throw RenderError("render returned nothing") }
        return try Node.parse(Data(json.utf8))
    }

    private func stateText(for target: Target?) -> String {
        var fields = Dictionary(uniqueKeysWithValues: state.map { ($0.key.rawValue, $0.value) })
        fields["settings"] = settings
        if case .bar(let display)? = target {
            fields["display"] = .object(["id": .string(display.id), "notched": .bool(display.notched)])
        }
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
