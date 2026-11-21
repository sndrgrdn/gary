import Foundation
import GaryCore
import Testing
@testable import gary

struct SkillTests {
    private let theme = try! JSON.parse(#"{"styles": {"panel": {"radius": 12}}, "colors": {"accent": "accent"}, "fonts": {"body": {"size": 12}}}"#)
    private var guide: String { Skill.guide(theme: theme, examples: [BundledExample(name: "load", summary: "A bar widget that shows the load.", manifest: nil)]) }

    @Test func documentsEveryCapabilityWithItsManifestEntryPermissionsAndDeclarations() {
        let guide = guide
        for capability in Capability.all {
            #expect(guide.contains("### \(capability.name)\n\n\(capability.summary)"), "\(capability.name)")
            #expect(guide.contains(capability.types.trimmingCharacters(in: .newlines)), "\(capability.name)")
            #expect(guide.contains("\"uses\": [\"\(capability.name)\"]") == (capability.install != nil), "\(capability.name)")
            #expect(guide.contains("\"subscribes\": [\"\(capability.name)\"]") == (capability.topic != nil), "\(capability.name)")
            for permission in capability.permissions { #expect(guide.contains("\(permission.name) (`\(permission.rawValue)`)"), "\(capability.name)") }
        }
    }

    @Test func documentsEveryPermissionCommandManifestFieldKindNodeAndLayer() throws {
        let guide = guide
        for permission in Permission.allCases { #expect(guide.contains("| `\(permission.rawValue)` | \(permission.name) |")) }
        for (syntax, _) in Request.usage + appUsage + skillUsage + pluginUsage { #expect(guide.contains("`gary \(syntax)`"), "\(syntax)") }
        let fields = try #require(PluginTypes.manifestSchema(try Capability.names())["properties"]?.object).keys
        for field in fields { #expect(guide.contains("`\(field)`"), "\(field)") }
        for kind in PluginKind.allCases { #expect(guide.contains("| `\(kind.rawValue)` |")) }
        for kind in Node.Kind.allCases { #expect(guide.contains("`\(kind.rawValue)`")) }
        for layer in SurfaceLayer.allCases { #expect(guide.contains("`\(layer.rawValue)`")) }
    }

    @Test func listsTheThemeAndTheBundledExamples() {
        let guide = guide
        #expect(guide.contains("- `panel`: `{\"radius\":12}`"))
        #expect(guide.contains("- `accent`: `\"accent\"`"))
        #expect(guide.contains("type StyleName = \"panel\""))
        #expect(guide.contains("- `load`. A bar widget that shows the load."))
    }
}
