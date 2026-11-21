import Foundation
@testable import GaryCore
import Testing

func makeTestCapabilities() throws -> CapabilityNames {
    try CapabilityNames([
        CapabilityDeclaration("battery", installs: false, publishes: true),
        CapabilityDeclaration("clock", installs: false, publishes: true),
        CapabilityDeclaration("exec", installs: true, publishes: false),
        CapabilityDeclaration("files", installs: true, publishes: false),
        CapabilityDeclaration("network", installs: true, publishes: false),
    ])
}

struct PluginManifestTests {
    private func manifest(
        _ fields: [String: JSON],
        origin: PluginOrigin = .user,
        capabilities: CapabilityNames? = nil,
    ) throws -> PluginManifest {
        var base: [String: JSON] = [
            "schemaVersion": 1, "id": "acme.media", "name": "Media", "version": "0.1.0",
            "kinds": ["bar-widget"], "entryPoints": ["bar-widget": "widget.js"],
        ]
        base.merge(fields) { $1 }
        return try PluginManifest.parse(JSON.object(base).encoded(), origin: origin, capabilities: capabilities ?? makeTestCapabilities())
    }

    private func rejects(_ fields: [String: JSON], with error: ManifestError, origin: PluginOrigin = .user) {
        #expect(throws: error) { try manifest(fields, origin: origin) }
    }

    @Test func `parses every field`() throws {
        let parsed = try manifest([
            "kinds": ["service", "bar-widget"],
            "entryPoints": ["service": "lib/service.ts", "bar-widget": "widget.js"],
            "keepLoaded": true, "subscribes": ["clock", "battery", "acme.counter"], "uses": ["exec", "network", "files"],
        ])
        #expect(parsed.id.rawValue == "acme.media")
        #expect(parsed.kinds == [.service, .barWidget])
        #expect(parsed.entryPoints == [.service: "lib/service.ts", .barWidget: "widget.js"])
        #expect(parsed.keepLoaded)
        #expect(try parsed.subscribes == [.capability("clock"), .capability("battery"), .plugin(#require(PluginID("acme.counter")))])
        #expect(parsed.uses == ["exec", "network", "files"])
    }

    @Test func `capabilities are the uses then the subscribed capability topics`() throws {
        let parsed = try manifest(["subscribes": ["clock", "acme.counter", "exec"], "uses": ["exec", "files"]], capabilities: CapabilityNames([
            CapabilityDeclaration("clock", installs: false, publishes: true), CapabilityDeclaration("exec", installs: true, publishes: true),
            CapabilityDeclaration(
                "files",
                installs: true,
                publishes: false,
            ),
        ]))
        #expect(parsed.capabilities == ["exec", "files", "clock"])
    }

    @Test func `a bar widget goes to the bar section the manifest names and to the right by default`() throws {
        #expect(try manifest([:]).barPlacement == .right)
        #expect(try manifest(["bar": "left"]).barPlacement == .left)
        #expect(try manifest(["bar": "left", "kinds": ["panel"], "entryPoints": ["panel": "p.js"]]).barPlacement == nil)
        rejects(["bar": "top"], with: .wrongType("bar"))
    }

    @Test func `optional fields default to off`() throws {
        let parsed = try manifest([:])
        #expect(!parsed.keepLoaded)
        #expect(parsed.subscribes.isEmpty)
        #expect(parsed.uses.isEmpty)
    }

    @Test func `rejects wrong schema version`() {
        rejects(["schemaVersion": 2], with: .unsupportedSchemaVersion(2))
        rejects(["schemaVersion": 1e300], with: .unsupportedSchemaVersion(1e300))
        rejects(["schemaVersion": -1e300], with: .unsupportedSchemaVersion(-1e300))
    }

    @Test func `rejects missing and mistyped fields`() throws {
        let capabilities = try makeTestCapabilities()
        #expect(throws: ManifestError.missingField("name")) {
            try PluginManifest.parse(
                Data(#"{"schemaVersion":1,"id":"a.b","version":"1","kinds":["panel"],"entryPoints":{"panel":"p.js"}}"#.utf8),
                origin: .user,
                capabilities: capabilities,
            )
        }
        rejects(["version": 1], with: .wrongType("version"))
        rejects(["kinds": "panel"], with: .wrongType("kinds"))
        #expect(throws: ManifestError.invalidJSON) { try PluginManifest.parse(Data("[1]".utf8), origin: .user, capabilities: capabilities) }
    }

    @Test func `rejects malformed IDs`() {
        for id in ["acme", "Acme.media", "acme..media", ".acme", "acme.media.", "acme/media", "acme media.x"] {
            rejects(["id": .string(id)], with: .invalidID(id))
        }
    }

    @Test func `reserves the gary namespace for builtins`() throws {
        try rejects(["id": "gary.clock"], with: .reservedID(#require(PluginID("gary.clock"))), origin: .user)
        try rejects(["id": "acme.clock"], with: .builtinOutsideNamespace(#require(PluginID("acme.clock"))), origin: .builtin)
        #expect(try manifest(["id": "gary.clock"], origin: .builtin).id.isReserved)
    }

    @Test func `kinds must be known unique and non empty`() {
        rejects(["kinds": []], with: .noKinds)
        rejects(["kinds": ["widget"]], with: .unknownKind("widget"))
        rejects(["kinds": ["panel", "panel"], "entryPoints": ["panel": "p.js"]], with: .duplicateKind(.panel))
    }

    @Test func `every kind needs an entry point and every entry point A kind`() {
        rejects(["kinds": ["bar-widget", "panel"]], with: .missingEntryPoint(.panel))
        rejects(["entryPoints": ["bar-widget": "w.js", "panel": "p.js"]], with: .entryPointWithoutKind("panel"))
    }

    @Test func `entry points stay inside the plugin as scripts`() {
        for path in ["../escape.js", "lib/../../escape.js", "/etc/x.js", "~/x.js", "widget.tsx", "widget.d", "./widget.js", "lib//w.js"] {
            rejects(["entryPoints": ["bar-widget": .string(path)]], with: .unsafeEntryPoint(path))
        }
    }

    @Test func `subscriptions and services must be known`() {
        rejects(["subscribes": ["weather"]], with: .unknownTopic("weather"))
        rejects(["subscribes": ["Acme.Counter"]], with: .unknownTopic("Acme.Counter"))
        rejects(["uses": ["dbus"]], with: .unknownService("dbus"))
    }

    @Test func `uses names capabilities with an API and subscribes names capabilities with A topic`() throws {
        let registry = try CapabilityNames([
            CapabilityDeclaration("wifi", installs: true, publishes: true),
            CapabilityDeclaration("volume", installs: true, publishes: false),
            CapabilityDeclaration("battery", installs: false, publishes: true),
        ])
        let parsed = try manifest(["uses": ["wifi", "volume"], "subscribes": ["wifi", "battery"]], capabilities: registry)
        #expect(parsed.uses == ["wifi", "volume"])
        #expect(parsed.subscribes == [.capability("wifi"), .capability("battery")])
        #expect(throws: ManifestError.unknownService("battery")) { try manifest(["uses": ["battery"]], capabilities: registry) }
        #expect(throws: ManifestError.unknownService("exec")) { try manifest(["uses": ["exec"]], capabilities: registry) }
        #expect(throws: ManifestError.unknownTopic("volume")) { try manifest(["subscribes": ["volume"]], capabilities: registry) }
        #expect(throws: ManifestError.unknownTopic("clock")) { try manifest(["subscribes": ["clock"]], capabilities: registry) }
    }

    @Test func `parses hotkeys into modifiers and key codes`() throws {
        let parsed = try manifest(["hotkeys": [
            ["id": "open", "keys": "ctrl+alt+space"],
            ["id": "next", "keys": "Cmd+Shift+F"],
            ["id": "f", "keys": "f5"],
        ]])
        #expect(parsed.hotkeys.map(\.id) == ["open", "next", "f"])
        #expect(parsed.hotkeys[0].keys.modifiers == [.control, .option] && parsed.hotkeys[0].keys.keyCode == 49)
        #expect(parsed.hotkeys[1].keys.modifiers == [.command, .shift] && parsed.hotkeys[1].keys.keyCode == 3)
        #expect(parsed.hotkeys[2].keys.modifiers.isEmpty && parsed.hotkeys[2].keys.keyCode == 96)
        #expect(parsed.hotkeys[0].keys.description == "ctrl+alt+space")
    }

    @Test func `rejects hotkeys without A modifier or with unknown keys`() {
        for keys in ["space", "shift+a", "ctrl+", "ctrl+ctrl+a", "hyper+a", "ctrl+alt+spacebar"] {
            rejects(["hotkeys": [["id": "x", "keys": .string(keys)]]], with: .invalidHotkey(keys))
        }
        rejects(["hotkeys": [["id": "x", "keys": "ctrl+a"], ["id": "x", "keys": "ctrl+b"]]], with: .duplicateHotkey("x"))
        rejects(["hotkeys": [["keys": "ctrl+a"]]], with: .wrongType("hotkeys[0]"))
    }
}

struct PluginCatalogTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gary-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    private func plugin(_ dir: String, id: String, in base: String = "user", entry: String = "widget.js", writeEntry: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent(base).appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"{"schemaVersion":1,"id":"\#(id)","name":"N","version":"1","kinds":["bar-widget"],"entryPoints":{"bar-widget":"\#(entry)"}}"#
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        if writeEntry {
            let file = directory.appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "module.exports = {}".write(to: file, atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func scan(packages: [String] = []) throws -> PluginCatalog {
        try PluginCatalog.scan(
            builtin: root.appendingPathComponent("builtin"),
            user: root.appendingPathComponent("user"),
            packages: packages.map { root.appendingPathComponent($0) },
            capabilities: makeTestCapabilities(),
        )
    }

    @Test func `finds builtin and user plugins`() throws {
        try plugin("clock", id: "gary.clock", in: "builtin")
        try plugin("media", id: "acme.media", entry: "src/widget.js")
        let catalog = try scan()
        #expect(catalog.sortedIDs.map(\.rawValue) == ["acme.media", "gary.clock"])
        #expect(catalog.problems.isEmpty)
        let mediaID = try #require(PluginID("acme.media"))
        let bundle = try #require(catalog.plugins[mediaID])
        let entry = try bundle.entryPoint(.barWidget)
        #expect(entry.path.hasSuffix("media/src/widget.js"))
    }

    @Test func `follows A user plugin folder that is A symlink`() throws {
        try plugin("media", id: "acme.media", in: "elsewhere")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("user"),
            withDestinationURL: root.appendingPathComponent("elsewhere"),
        )
        #expect(try scan().sortedIDs.map(\.rawValue) == ["acme.media"])
    }

    @Test func `reports A user plugin that claims A builtin ID`() throws {
        try plugin("clock", id: "gary.clock", in: "builtin")
        try plugin("fake-clock", id: "gary.clock")
        let catalog = try scan()
        #expect(try catalog.plugins[#require(PluginID("gary.clock"))]?.origin == .builtin)
        #expect(catalog.problems.map(\.directory.lastPathComponent) == ["fake-clock"])
    }

    @Test func `keeps the first of two user plugins with one ID`() throws {
        try plugin("a", id: "acme.media")
        try plugin("b", id: "acme.media")
        let catalog = try scan()
        #expect(try catalog.plugins[#require(PluginID("acme.media"))]?.directory.lastPathComponent == "a")
        #expect(catalog.problems.count == 1)
    }

    @Test func `a package with A root manifest is one plugin and otherwise each subfolder with A manifest is one`() throws {
        try plugin("single", id: "acme.single", in: "packages")
        try plugin("a", id: "acme.a", in: "packages/multi")
        try plugin("b", id: "acme.b", in: "packages/multi")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("packages/multi/docs"), withIntermediateDirectories: true)
        try plugin(".hidden", id: "acme.hidden", in: "packages/multi")
        #expect(PluginCatalog.pluginDirectories(inPackage: root.appendingPathComponent("packages/multi")).map(\.lastPathComponent) == ["a", "b"])
        let catalog = try scan(packages: ["packages/single", "packages/multi"])
        #expect(catalog.sortedIDs.map(\.rawValue) == ["acme.a", "acme.b", "acme.single"])
        #expect(catalog.problems.isEmpty)
    }

    @Test func `the plugins folder wins over packages and the first package wins over later ones`() throws {
        try plugin("media", id: "acme.media")
        try plugin("media", id: "acme.media", in: "packages/one")
        try plugin("media", id: "acme.media", in: "packages/two")
        let catalog = try scan(packages: ["packages/one/media", "packages/two"])
        #expect(try catalog.plugins[#require(PluginID("acme.media"))]?.directory.path.contains("/user/") == true)
        #expect(catalog.problems.map { $0.directory.deletingLastPathComponent().lastPathComponent } == ["one", "two"])
    }

    @Test func `rejects symlinked entry points and directories`() throws {
        let outside = root.appendingPathComponent("outside.js")
        try "while(true){}".write(to: outside, atomically: true, encoding: .utf8)
        let linked = try plugin("linked", id: "acme.linked", writeEntry: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("widget.js"), withDestinationURL: outside)
        let nested = try plugin("nested", id: "acme.nested", entry: "lib/widget.js", writeEntry: false)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("lib"), withDestinationURL: root)

        let catalog = try scan()
        #expect(catalog.plugins.isEmpty)
        #expect(catalog.problems.map(\.reason).sorted() == ["lib/widget.js is a symlink", "widget.js is a symlink"])
    }

    @Test func `reports A missing entry point and A bad manifest`() throws {
        try plugin("missing", id: "acme.missing", writeEntry: false)
        let bad = root.appendingPathComponent("user/bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "{".write(to: bad.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let catalog = try scan()
        #expect(catalog.plugins.isEmpty)
        #expect(catalog.problems.map(\.reason).sorted() == ["manifest is not a JSON object", "widget.js does not exist"])
    }

    @Test func `entry point is checked again at load`() throws {
        let directory = try plugin("media", id: "acme.media")
        let mediaID = try #require(PluginID("acme.media"))
        let bundle = try #require(try scan().plugins[mediaID])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("widget.js"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("widget.js"), withDestinationURL: root)
        #expect(throws: PluginFileError.symlink("widget.js")) { try bundle.entryPoint(.barWidget) }
    }
}
