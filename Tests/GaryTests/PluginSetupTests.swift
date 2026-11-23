import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor struct PluginSetupTests {
    private let folder = ConfigFolder()

    private func plugin(_ id: String, _ kinds: [PluginKind], in parent: String = "plugins") throws {
        let names = kinds.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        let entries = kinds.map { "\"\($0.rawValue)\": \"\($0.rawValue).js\"" }.joined(separator: ", ")
        try folder.write(
            "\(parent)/\(id)/manifest.json",
            #"{"schemaVersion": 1, "id": "\#(id)", "name": "\#(id)", "version": "1", "kinds": [\#(names)], "entryPoints": {\#(entries)}}"#,
        )
        for kind in kinds {
            try folder.write("\(parent)/\(id)/\(kind.rawValue).js", "export default {}")
        }
    }

    private func id(_ raw: String) throws -> PluginID {
        try #require(PluginID(raw))
    }

    private func loaded() -> PluginSetup {
        let setup = PluginSetup(files: folder.files)
        _ = setup.refresh(config: true, catalog: true)
        return setup
    }

    @Test func `without a shell.json the defaults apply, and a shell.json that fails to parse keeps the config Gary runs`() throws {
        try plugin("test.panel", [.panel])
        let setup = PluginSetup(files: folder.files)
        #expect(setup.refresh(config: true, catalog: true).response == .ok("no shell.json; using defaults"))
        #expect(try !setup.resolution.enabled.contains(id("test.panel")))

        try folder.write("shell.json", #"{"plugins": ["test.panel"]}"#)
        let enabled = setup.refresh(config: true, catalog: false)
        #expect(enabled.response == .ok("config loaded"))
        #expect(enabled.resolved)
        #expect(try setup.resolution.enabled.contains(id("test.panel")))

        try folder.write("shell.json", "{ not json")
        let broken = setup.refresh(config: true, catalog: false)
        if case .ok = broken.response {
            Issue.record("a broken shell.json loaded")
        }
        #expect(!broken.resolved)
        #expect(try setup.resolution.enabled.contains(id("test.panel")))
    }

    @Test func `a saved shell.json that changes nothing resolves nothing, and a changed setting names only its plugin`() throws {
        try plugin("test.panel", [.panel])
        try plugin("test.menu", [.menu])
        try folder.write("shell.json", #"{"plugins": ["test.panel", "test.menu"], "settings": {"test.menu": {"size": 1}}}"#)
        let setup = loaded()

        #expect(!setup.refresh(config: true, catalog: false).resolved)

        try folder.write(
            "shell.json",
            #"{"plugins": ["test.panel", "test.menu"], "settings": {"test.panel": {"size": 2}, "test.menu": {"size": 1}}}"#,
        )
        let changed = setup.refresh(config: true, catalog: false)
        #expect(changed.resolved)
        #expect(try changed.settingsChanged == [id("test.panel")])
        #expect(!changed.packagesChanged)
    }

    @Test func `a new package is scanned with the shell.json that names it, and a rescan finds a new plugin folder`() throws {
        try plugin("test.packaged", [.panel], in: "package")
        let setup = loaded()
        #expect(try setup.catalog.plugins[id("test.packaged")] == nil)

        try folder.write("shell.json", #"{"packages": ["\#(folder.url.appending(path: "package").path)"], "plugins": ["test.packaged"]}"#)
        let declared = setup.refresh(config: true, catalog: false)
        #expect(declared.packagesChanged)
        #expect(declared.resolved)
        #expect(try setup.resolution.enabled.contains(id("test.packaged")))

        try plugin("test.later", [.service])
        #expect(try setup.catalog.plugins[id("test.later")] == nil)
        let rescanned = setup.refresh(config: false, catalog: true)
        #expect(rescanned.resolved)
        #expect(!rescanned.packagesChanged)
        #expect(try setup.catalog.plugins[id("test.later")] != nil)
    }

    @Test func `bar widgets want slots only while the built-in bar shows, and a bar plugin, surfaces and services always do`() throws {
        try plugin("test.widget", [.barWidget])
        try plugin("test.bar", [.bar])
        try plugin("test.panel", [.panel, .service])
        try plugin("test.off", [.panel])
        try folder.write("shell.json", #"{"bar": {"right": ["test.widget"]}, "plugins": ["test.bar", "test.panel"]}"#)
        let setup = loaded()

        let always = try Set([
            SlotKey(id: id("test.bar"), kind: .bar),
            SlotKey(id: id("test.panel"), kind: .panel),
            SlotKey(id: id("test.panel"), kind: .service),
        ])
        #expect(Set(setup.wanted(builtinBar: false).keys) == always)
        #expect(try Set(setup.wanted(builtinBar: true).keys) == always.union([SlotKey(id: id("test.widget"), kind: .barWidget)]))
    }
}
