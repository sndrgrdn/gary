import CryptoKit
import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

final nonisolated class Transpiler: @unchecked Sendable {
    static let shared = Transpiler(sucrase: Paths.sucrase, cache: Paths.transpiled)
    static let idle: TimeInterval = 30
    private static let options = #"{ disableESTransforms: true, production: true, jsxPragma: "Gary.h", jsxFragmentPragma: "Gary.Fragment" }"#

    private let sucrase: URL
    private let cache: URL
    private let version: Data
    private let lock = NSLock()
    private var loaded: (context: JSContext, transform: JSValue)?
    private var release: DispatchWorkItem?

    init(sucrase: URL, cache: URL) {
        self.sucrase = sucrase
        self.cache = cache
        version = Data(SHA256.hash(data: ((try? Data(contentsOf: sucrase)) ?? Data()) + Data(Self.options.utf8)))
    }

    func modules(of bundle: PluginBundle, from entry: String) throws -> [PluginModule] {
        var modules: [PluginModule] = []
        var pending = [entry]
        var seen: Set = [entry]
        while let path = pending.popLast() {
            let url = bundle.directory.appending(path: path)
            let code = try compile(String(contentsOf: url, encoding: .utf8), at: url, path: path)
            var links: [String: String] = [:]
            for match in code.matches(of: #/require\(['"]([^'"\n]+)['"]\)/#) {
                let specifier = String(match.1)
                let target = try bundle.resolveImport(specifier, from: path)
                links[specifier] = target
                if target != PluginBundle.effectModule, seen.insert(target).inserted {
                    pending.append(target)
                }
            }
            modules.append(PluginModule(path: path, url: url, code: code, links: links))
        }
        return modules
    }

    private func compile(_ source: String, at url: URL, path: String) throws -> String {
        guard let language = ScriptLanguage(path: path) else { throw RenderError("\(path) is not a script") }
        let key = SHA256.hash(data: version + Data((language.transforms.joined(separator: ",") + "\n" + source).utf8)).hex + "\n"
        let cached = cache.appending(path: SHA256.hash(data: Data(url.path.utf8)).hex + ".js")
        if let entry = try? String(contentsOf: cached, encoding: .utf8), entry.hasPrefix(key) {
            return String(entry.dropFirst(key.count))
        }
        let code = try transpile(source, path: path, language: language)
        if !code.isEmpty {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? Data((key + code).utf8).write(to: cached, options: .atomic)
        }
        return code
    }

    private func transpile(_ source: String, path: String, language: ScriptLanguage) throws -> String {
        try lock.withLock {
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
          return Sucrase.transform(source, Object.assign({ transforms: transforms }, \(Self.options))).code;
        })
        """), transform.isObject else { throw RenderError("cannot load the transpiler from \(sucrase.path)") }
        return (context, transform)
    }
}

nonisolated struct PluginModule {
    let path: String
    let url: URL
    let code: String
    let links: [String: String]
}

private nonisolated extension SHA256.Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated extension ScriptLanguage {
    var transforms: [String] {
        switch self {
        case .typescript: ["typescript", "imports"]
        case .tsx: ["typescript", "jsx", "imports"]
        case .javascript: ["imports"]
        }
    }
}
