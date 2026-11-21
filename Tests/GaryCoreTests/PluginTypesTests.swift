import Foundation
import Testing
@testable import GaryCore

struct PluginTypesTests {
    private let theme = try! JSON.parse(#"{"styles": {"default": {}, "title": {}}, "fonts": {"body": {}}, "colors": {"accent": "accent"}}"#)

    @Test func declaresEveryNodeKindStylePropKindAndLayerTheRuntimeParses() {
        let text = PluginTypes.declarations(capabilities: [], pluginTopics: [], theme: nil)
        for kind in Node.Kind.allCases { #expect(text.contains("type: \"\(kind.rawValue)\";")) }
        for (name, _) in StyleProps.numbers { #expect(text.contains("\(name)?: number;")) }
        for (name, _) in StyleProps.colors { #expect(text.contains("\(name)?: Color;")) }
        for kind in PluginKind.allCases { #expect(text.contains("type \(PluginTypes.typeName(kind.rawValue)) = ")) }
        for layer in SurfaceLayer.allCases { #expect(text.contains("\"\(layer.rawValue)\"")) }
    }

    @Test func addsCapabilityDeclarationsPluginTopicsAndThemeNames() {
        let text = PluginTypes.declarations(
            capabilities: ["declare namespace Gary { interface State { clock?: Clock } }"], pluginTopics: [PluginID("acme.counter")!], theme: theme
        )
        #expect(text.hasSuffix("declare namespace Gary { interface State { clock?: Clock } }\n"))
        #expect(text.contains("\"acme.counter\"?: Json;"))
        #expect(text.contains("type StyleName = \"default\" | \"title\" | (string & {});"))
        #expect(text.contains("type FontName = \"body\" | (string & {});"))
        #expect(text.contains("type ColorName = \"accent\" | (string & {});"))
    }

    @Test func theManifestSchemaListsTheRegisteredCapabilitiesAndKinds() throws {
        let schema = PluginTypes.manifestSchema(testCapabilities)
        let properties = try #require(schema["properties"])
        #expect(properties["uses"]?["items"]?["enum"] == .array(["exec", "files", "network"].map(JSON.string)))
        #expect(properties["subscribes"]?["items"]?["anyOf"]?.array?.first?["enum"] == .array(["battery", "clock"].map(JSON.string)))
        #expect(properties["kinds"]?["items"]?["enum"] == .array(PluginKind.allCases.map { .string($0.rawValue) }))
        #expect(properties["schemaVersion"]?["const"] == .number(Double(PluginManifest.schemaVersion)))
    }
}

struct PluginScaffoldTests {
    @Test func everyScaffoldPassesTheLoadTimeChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gary-scaffold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for kinds in PluginKind.allCases.map({ [$0] }) + [[.service, .barWidget], [.panel, .service]] {
            let directory = root.appendingPathComponent(kinds.map(\.rawValue).joined(separator: "+"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = PluginID("acme.hello-world")!
            for (name, text) in PluginScaffold.files(id: id, kinds: kinds) {
                try Data(text.utf8).write(to: directory.appendingPathComponent(name))
            }
            let bundle = try PluginBundle.load(directory, origin: .user, capabilities: testCapabilities)
            #expect(bundle.manifest.id == id)
            #expect(bundle.manifest.name == "Hello World")
            #expect(bundle.manifest.kinds == kinds)
            for kind in kinds { #expect(try bundle.entryPoint(kind).lastPathComponent == PluginScaffold.entryFile(kind)) }
        }
    }
}

struct ExamplePluginTests {
    @Test func everyExamplePassesTheLoadTimeChecks() throws {
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../examples").standardizedFileURL
        let directories = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath)
        #expect(directories.count >= 3)
        for directory in directories {
            #expect(throws: Never.self, "\(directory.lastPathComponent)") { try PluginBundle.load(directory, origin: .user, capabilities: testCapabilities) }
        }
    }
}
