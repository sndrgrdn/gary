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
