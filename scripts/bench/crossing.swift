import Foundation
import JavaScriptCore

extension JSON {
    init(any value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSON.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(value): value.map(\.any)
        case let .object(value): value.mapValues(\.any)
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("crossing: \(message)\n".utf8))
    exit(64)
}

func median(_ runs: Int, _ body: () -> Void) -> Double {
    body()
    let times = (0..<runs).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    return times.sorted()[runs / 2]
}

func report(_ name: String, _ milliseconds: Double) {
    print(String(format: "%@ ms=%.3f", name, milliseconds))
}

@main
enum Crossing {
    static func main() {
        guard CommandLine.arguments.count == 3, let nodes = Int(CommandLine.arguments[2]) else { fail("usage: crossing <plugins folder> <nodes>") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let context = JSContext() else { fail("no JavaScript context") }
        context.exceptionHandler = { _, value in fail(value?.toString() ?? "exception") }
        context.evaluateScript("var module = { exports: {} }; var host = { publish: function () {} };")
        context.evaluateScript("var setInterval = function () { return 1; }; var clearInterval = function () {};")
        guard let panel = try? String(contentsOf: folder.appending(path: "bench.busy/panel.js"), encoding: .utf8),
              let feed = try? String(contentsOf: folder.appending(path: "bench.feed/service.js"), encoding: .utf8) else { fail("no bench plugins") }
        context.evaluateScript("(function () { \(panel) ; globalThis.panel = module.exports; module = { exports: {} }; })()")
        context
            .evaluateScript(
                "(function () { \(feed) ; globalThis.feed = module.exports; globalThis.feedState = function () { return { items, published }; }; })()",
            )
        guard let tree = context.evaluateScript("panel.render({ settings: { nodes: \(nodes), hz: 0 } })"),
              let stringify = context.evaluateScript("(function (v) { return JSON.stringify(v); })"),
              let parse = context.evaluateScript("(function (s) { return JSON.parse(s); })"),
              let text = stringify.call(withArguments: [tree]).toString() else { fail("render failed") }
        let data = Data(text.utf8)
        let runs = 41

        print("tree nodes=\(nodes) bytes=\(data.count)")
        report("tree stringify_in_js", median(runs) { _ = stringify.call(withArguments: [tree]).toString() })
        report("tree json_parse", median(runs) { _ = try? JSON.parse(text) })
        report("tree jsonserialization", median(runs) { _ = (try? JSONSerialization.jsonObject(with: data)).map(JSON.init(any:)) })
        report("tree jsvalue_toobject", median(runs) { _ = tree.toObject().map(JSON.init(any:)) })

        context.evaluateScript("feed.methods.start(200000)")
        guard let stateValue = context.evaluateScript("({ 'bench.feed': feedState() })"),
              let stateText = stringify.call(withArguments: [stateValue]).toString(),
              let state = try? JSON.parse(stateText) else { fail("state failed") }
        print("state bytes=\(stateText.utf8.count)")
        report("state json_parse", median(runs) { _ = try? JSON.parse(stateText) })
        report("state json_text", median(runs) { _ = state.text })
        report("state jsonserialization", median(runs) { _ = try? JSONSerialization.data(withJSONObject: state.any) })
        report("state parse_in_js", median(runs) { _ = parse.call(withArguments: [stateText]) })
        report("state jsvalue_from_object", median(runs) { _ = JSValue(object: state.any, in: context) })
    }
}
