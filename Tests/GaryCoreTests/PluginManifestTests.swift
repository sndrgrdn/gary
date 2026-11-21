import Foundation
import Testing
@testable import GaryCore

let testCapabilities = try! CapabilityNames([("battery", false, true), ("clock", false, true), ("exec", true, false), ("files", true, false), ("network", true, false)])

struct PluginManifestTests {
    private func manifest(_ fields: [String: Any], origin: PluginOrigin = .user, capabilities: CapabilityNames = testCapabilities) throws -> PluginManifest {
        var base: [String: Any] = [
            "schemaVersion": 1, "id": "acme.media", "name": "Media", "version": "0.1.0",
            "kinds": ["bar-widget"], "entryPoints": ["bar-widget": "widget.js"],
        ]
        base.merge(fields) { $1 }
        return try PluginManifest.parse(try JSONSerialization.data(withJSONObject: base), origin: origin, capabilities: capabilities)
    }

    private func rejects(_ fields: [String: Any], origin: PluginOrigin = .user, with error: ManifestError) {
        #expect(throws: error) { try manifest(fields, origin: origin) }
    }

    @Test func parsesEveryField() throws {
        let parsed = try manifest([
            "kinds": ["service", "bar-widget"],
            "entryPoints": ["service": "lib/service.ts", "bar-widget": "widget.js"],
            "keepLoaded": true, "subscribes": ["clock", "battery", "acme.counter"], "uses": ["exec", "network", "files"],
        ])
        #expect(parsed.id.rawValue == "acme.media")
        #expect(parsed.kinds == [.service, .barWidget])
        #expect(parsed.entryPoints == [.service: "lib/service.ts", .barWidget: "widget.js"])
        #expect(parsed.keepLoaded)
        #expect(parsed.subscribes == [.capability("clock"), .capability("battery"), .plugin(PluginID("acme.counter")!)])
        #expect(parsed.uses == ["exec", "network", "files"])
    }

    @Test func optionalFieldsDefaultToOff() throws {
        let parsed = try manifest([:])
        #expect(!parsed.keepLoaded)
        #expect(parsed.subscribes.isEmpty)
        #expect(parsed.uses.isEmpty)
    }

    @Test func rejectsWrongSchemaVersion() {
        rejects(["schemaVersion": 2], with: .unsupportedSchemaVersion(2))
    }

    @Test func rejectsMissingAndMistypedFields() {
        #expect(throws: ManifestError.missingField("name")) {
            try PluginManifest.parse(Data(#"{"schemaVersion":1,"id":"a.b","version":"1","kinds":["panel"],"entryPoints":{"panel":"p.js"}}"#.utf8), origin: .user, capabilities: testCapabilities)
        }
        rejects(["version": 1], with: .wrongType("version"))
        rejects(["kinds": "panel"], with: .wrongType("kinds"))
        #expect(throws: ManifestError.invalidJSON) { try PluginManifest.parse(Data("[1]".utf8), origin: .user, capabilities: testCapabilities) }
    }

    @Test func rejectsMalformedIDs() {
        for id in ["acme", "Acme.media", "acme..media", ".acme", "acme.media.", "acme/media", "acme media.x"] {
            rejects(["id": id], with: .invalidID(id))
        }
    }

    @Test func reservesTheGaryNamespaceForBuiltins() throws {
        rejects(["id": "gary.clock"], origin: .user, with: .reservedID(PluginID("gary.clock")!))
        rejects(["id": "acme.clock"], origin: .builtin, with: .builtinOutsideNamespace(PluginID("acme.clock")!))
        #expect(try manifest(["id": "gary.clock"], origin: .builtin).id.isReserved)
    }

    @Test func kindsMustBeKnownUniqueAndNonEmpty() {
        rejects(["kinds": []], with: .noKinds)
        rejects(["kinds": ["widget"]], with: .unknownKind("widget"))
        rejects(["kinds": ["panel", "panel"], "entryPoints": ["panel": "p.js"]], with: .duplicateKind(.panel))
    }

    @Test func everyKindNeedsAnEntryPointAndEveryEntryPointAKind() {
        rejects(["kinds": ["bar-widget", "panel"]], with: .missingEntryPoint(.panel))
        rejects(["entryPoints": ["bar-widget": "w.js", "panel": "p.js"]], with: .entryPointWithoutKind("panel"))
    }

    @Test func entryPointsStayInsideThePluginAsScripts() {
        for path in ["../escape.js", "lib/../../escape.js", "/etc/x.js", "~/x.js", "widget.tsx", "widget.d", "./widget.js", "lib//w.js"] {
            rejects(["entryPoints": ["bar-widget": path]], with: .unsafeEntryPoint(path))
        }
    }

    @Test func subscriptionsAndServicesMustBeKnown() {
        rejects(["subscribes": ["weather"]], with: .unknownTopic("weather"))
        rejects(["subscribes": ["Acme.Counter"]], with: .unknownTopic("Acme.Counter"))
        rejects(["uses": ["dbus"]], with: .unknownService("dbus"))
    }

    @Test func usesNamesCapabilitiesWithAnAPIAndSubscribesNamesCapabilitiesWithATopic() throws {
        let registry = try CapabilityNames([("wifi", true, true), ("volume", true, false), ("battery", false, true)])
        let parsed = try manifest(["uses": ["wifi", "volume"], "subscribes": ["wifi", "battery"]], capabilities: registry)
        #expect(parsed.uses == ["wifi", "volume"])
        #expect(parsed.subscribes == [.capability("wifi"), .capability("battery")])
        #expect(throws: ManifestError.unknownService("battery")) { try manifest(["uses": ["battery"]], capabilities: registry) }
        #expect(throws: ManifestError.unknownService("exec")) { try manifest(["uses": ["exec"]], capabilities: registry) }
        #expect(throws: ManifestError.unknownTopic("volume")) { try manifest(["subscribes": ["volume"]], capabilities: registry) }
        #expect(throws: ManifestError.unknownTopic("clock")) { try manifest(["subscribes": ["clock"]], capabilities: registry) }
    }

    @Test func parsesHotkeysIntoModifiersAndKeyCodes() throws {
        let parsed = try manifest(["hotkeys": [["id": "open", "keys": "ctrl+alt+space"], ["id": "next", "keys": "Cmd+Shift+F"], ["id": "f", "keys": "f5"]]])
        #expect(parsed.hotkeys.map(\.id) == ["open", "next", "f"])
        #expect(parsed.hotkeys[0].keys.modifiers == [.control, .option] && parsed.hotkeys[0].keys.keyCode == 49)
        #expect(parsed.hotkeys[1].keys.modifiers == [.command, .shift] && parsed.hotkeys[1].keys.keyCode == 3)
        #expect(parsed.hotkeys[2].keys.modifiers.isEmpty && parsed.hotkeys[2].keys.keyCode == 96)
        #expect(parsed.hotkeys[0].keys.description == "ctrl+alt+space")
    }

    @Test func rejectsHotkeysWithoutAModifierOrWithUnknownKeys() {
        for keys in ["space", "shift+a", "ctrl+", "ctrl+ctrl+a", "hyper+a", "ctrl+alt+spacebar"] {
            rejects(["hotkeys": [["id": "x", "keys": keys]]], with: .invalidHotkey(keys))
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

    private func scan() -> PluginCatalog {
        PluginCatalog.scan(builtin: root.appendingPathComponent("builtin"), user: root.appendingPathComponent("user"), capabilities: testCapabilities)
    }

    @Test func findsBuiltinAndUserPlugins() throws {
        try plugin("clock", id: "gary.clock", in: "builtin")
        try plugin("media", id: "acme.media", entry: "src/widget.js")
        let catalog = scan()
        #expect(catalog.sortedIDs.map(\.rawValue) == ["acme.media", "gary.clock"])
        #expect(catalog.problems.isEmpty)
        let entry = try catalog.plugins[PluginID("acme.media")!]!.entryPoint(.barWidget)
        #expect(entry.path.hasSuffix("media/src/widget.js"))
    }

    @Test func reportsAUserPluginThatClaimsABuiltinID() throws {
        try plugin("clock", id: "gary.clock", in: "builtin")
        try plugin("fake-clock", id: "gary.clock")
        let catalog = scan()
        #expect(catalog.plugins[PluginID("gary.clock")!]?.origin == .builtin)
        #expect(catalog.problems.map(\.directory.lastPathComponent) == ["fake-clock"])
    }

    @Test func keepsTheFirstOfTwoUserPluginsWithOneID() throws {
        try plugin("a", id: "acme.media")
        try plugin("b", id: "acme.media")
        let catalog = scan()
        #expect(catalog.plugins[PluginID("acme.media")!]?.directory.lastPathComponent == "a")
        #expect(catalog.problems.count == 1)
    }

    @Test func rejectsSymlinkedEntryPointsAndDirectories() throws {
        let outside = root.appendingPathComponent("outside.js")
        try "while(true){}".write(to: outside, atomically: true, encoding: .utf8)
        let linked = try plugin("linked", id: "acme.linked", writeEntry: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("widget.js"), withDestinationURL: outside)
        let nested = try plugin("nested", id: "acme.nested", entry: "lib/widget.js", writeEntry: false)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("lib"), withDestinationURL: root)

        let catalog = scan()
        #expect(catalog.plugins.isEmpty)
        #expect(catalog.problems.map(\.reason).sorted() == ["lib/widget.js is a symlink", "widget.js is a symlink"])
    }

    @Test func reportsAMissingEntryPointAndABadManifest() throws {
        try plugin("missing", id: "acme.missing", writeEntry: false)
        let bad = root.appendingPathComponent("user/bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "{".write(to: bad.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let catalog = scan()
        #expect(catalog.plugins.isEmpty)
        #expect(catalog.problems.map(\.reason).sorted() == ["manifest is not a JSON object", "widget.js does not exist"])
    }

    @Test func entryPointIsCheckedAgainAtLoad() throws {
        let directory = try plugin("media", id: "acme.media")
        let bundle = try #require(scan().plugins[PluginID("acme.media")!])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("widget.js"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("widget.js"), withDestinationURL: root)
        #expect(throws: PluginFileError.symlink("widget.js")) { try bundle.entryPoint(.barWidget) }
    }

}
