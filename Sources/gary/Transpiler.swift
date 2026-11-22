import Foundation
import GaryCore
import JavaScriptCore

final class Transpiler {
    static let shared = Transpiler(sucrase: Paths.sucrase)
    static let idle: TimeInterval = 30

    private let sucrase: URL
    private let lock = NSLock()
    private var loaded: (context: JSContext, transform: JSValue)?
    private var release: DispatchWorkItem?

    init(sucrase: URL) {
        self.sucrase = sucrase
    }

    func modules(of bundle: PluginBundle, from entry: String) throws -> [PluginModule] {
        var modules: [PluginModule] = []
        var pending = [entry]
        var seen: Set = [entry]
        while let path = pending.popLast() {
            let url = bundle.directory.appending(path: path)
            let code = try compile(String(contentsOf: url, encoding: .utf8), path: path)
            var links: [String: String] = [:]
            for match in code.matches(of: #/require\(['"]([^'"\n]+)['"]\)/#) {
                let specifier = String(match.1)
                let target = try bundle.resolveImport(specifier, from: path)
                links[specifier] = target
                if seen.insert(target).inserted {
                    pending.append(target)
                }
            }
            modules.append(PluginModule(path: path, url: url, code: code, links: links))
        }
        return modules
    }

    private func compile(_ source: String, path: String) throws -> String {
        guard let language = ScriptLanguage(path: path) else { throw RenderError("\(path) is not a script") }
        return try lock.withLock {
            let started = now()
            let warm = loaded != nil
            let (context, transform) = try loaded ?? load()
            loaded = (context, transform)
            release?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.lock.withLock { self?.loaded = nil } }
            release = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idle, execute: work)
            context.exception = nil
            let result = transform.call(withArguments: [source, language.transforms])
            if tracing {
                log(String(format: "transpile file=%@ loaded=%@ ms=%.3f", path, warm ? "warm" : "cold", (now() - started) * 1000))
            }
            if let exception = context.exception {
                throw RenderError("\(path): \(exception)")
            }
            return result?.toString() ?? ""
        }
    }

    private func load() throws -> (context: JSContext, transform: JSValue) {
        guard let context = JSContext() else { throw RenderError("cannot load the transpiler: no JavaScript context") }
        try context.evaluateScript(String(contentsOf: sucrase, encoding: .utf8), withSourceURL: sucrase)
        guard context.exception == nil, let transform = context.evaluateScript("""
        (function (source, transforms) {
          return Sucrase.transform(source, { transforms: transforms, disableESTransforms: true }).code;
        })
        """), transform.isObject else { throw RenderError("cannot load the transpiler from \(sucrase.path)") }
        return (context, transform)
    }
}

struct PluginModule {
    let path: String
    let url: URL
    let code: String
    let links: [String: String]
}

private extension ScriptLanguage {
    var transforms: [String] {
        switch self {
        case .typescript: ["typescript", "imports"]
        case .tsx: ["typescript", "jsx", "imports"]
        case .javascript: ["imports"]
        }
    }
}
