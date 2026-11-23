import Foundation
@testable import gary
import GaryCore
import Testing

private struct Workspace {
    let root = FileManager.default.temporaryDirectory.appending(path: "gary-transpiler-\(UUID().uuidString)")
    var plugin: URL {
        root.appending(path: "plugin")
    }

    var cache: URL {
        root.appending(path: "cache")
    }

    init() throws {
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let manifest = JSON.object([
            "schemaVersion": .number(1),
            "id": .string("test.transpiler"),
            "name": .string("Transpiler"),
            "version": .string("0.1.0"),
            "kinds": .array([.string("service")]),
            "entryPoints": .object(["service": .string("main.js")]),
        ])
        try Data(manifest.text.utf8).write(to: plugin.appending(path: "manifest.json"))
    }

    func transpiler(_ marker: String, emptyFirst: Bool = false) throws -> Transpiler {
        let sucrase = root.appending(path: "sucrase-\(marker).js")
        try Data("""
        var calls = 0;
        var Sucrase = {
          transform: function (source) {
            calls += 1;
            return { code: \(emptyFirst) && calls === 1 ? "" : source + " // \(marker) " + calls };
          },
        };
        """.utf8).write(to: sucrase)
        return Transpiler(sucrase: sucrase, cache: cache)
    }

    func code(_ source: String, with transpiler: Transpiler) throws -> String {
        try Data(source.utf8).write(to: plugin.appending(path: "main.js"))
        let bundle = try PluginBundle.load(plugin, origin: .user, capabilities: Capability.names())
        return try #require(transpiler.modules(of: bundle, from: "main.js").first).code
    }
}

struct TranspilerTests {
    @Test func `an unchanged module is served from the cache instead of transpiled again`() throws {
        let workspace = try Workspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let transpiler = try workspace.transpiler("a")
        #expect(try workspace.code("x", with: transpiler) == "x // a 1")
        #expect(try workspace.code("x", with: transpiler) == "x // a 1")
    }

    @Test func `a changed module or transpiler gets fresh output and replaces the module's one cache entry`() throws {
        let workspace = try Workspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let first = try workspace.transpiler("a")
        #expect(try workspace.code("x", with: first) == "x // a 1")
        #expect(try workspace.code("y", with: first) == "y // a 2")
        #expect(try workspace.code("y", with: workspace.transpiler("b")) == "y // b 1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.cache.path).count == 1)
    }

    @Test func `an empty transpile result is not cached`() throws {
        let workspace = try Workspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let transpiler = try workspace.transpiler("a", emptyFirst: true)
        #expect(try workspace.code("x", with: transpiler).isEmpty)
        #expect(try workspace.code("x", with: transpiler) == "x // a 2")
    }
}
