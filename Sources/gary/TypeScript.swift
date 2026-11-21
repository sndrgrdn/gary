import Foundation
import JavaScriptCore

final class TypeScript {
    static let shared = TypeScript()
    static let idle: TimeInterval = 30

    private let lock = NSLock()
    private var transform: JSValue?
    private var release: DispatchWorkItem?

    func strip(_ source: String, file: String) throws -> String {
        try lock.withLock {
            let started = now()
            let loaded = self.transform != nil
            let transform = try self.transform ?? load()
            self.transform = transform
            release?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.lock.withLock { self?.transform = nil } }
            release = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idle, execute: work)
            let context = transform.context!
            context.exception = nil
            let result = transform.call(withArguments: [source])
            if tracing {
                log(String(format: "typescript file=%@ loaded=%@ ms=%.3f", file, loaded ? "warm" : "cold", (now() - started) * 1000))
            }
            if let exception = context.exception {
                throw RenderError("\(file): \(exception)")
            }
            return result?.toString() ?? ""
        }
    }

    private func load() throws -> JSValue {
        let url = Bundle.main.resourceURL!.appending(path: "sucrase.js")
        let context = JSContext()!
        try context.evaluateScript(String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        guard context.exception == nil, let transform = context.evaluateScript("""
        (function (source) {
          return Sucrase.transform(source, { transforms: ["typescript"], disableESTransforms: true }).code;
        })
        """), transform.isObject else { throw RenderError("cannot load the TypeScript transpiler from \(url.path)") }
        return transform
    }
}
