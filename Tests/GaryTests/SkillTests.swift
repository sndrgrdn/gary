import Foundation
import GaryCore
import Testing
@testable import gary

private let deno = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appending(path: "deno") }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }

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

    @Test func showsAnExampleEntryFileForEveryCapability() {
        let guide = guide
        for capability in Capability.all {
            #expect(capability.example.contains("module.exports = {") && capability.example.contains("} satisfies Gary."), "\(capability.name)")
            #expect(guide.contains("```ts\n\(capability.example.trimmingCharacters(in: .newlines))\n```"), "\(capability.name)")
        }
    }

    @Test(.enabled(if: deno != nil, "deno is not installed")) func everyCapabilityExampleAndBuiltInPluginTypeChecks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gary-examples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let declarations = PluginTypes.declarations(capabilities: Capability.all.map(\.types), pluginTopics: [], theme: nil)
        try Data(declarations.utf8).write(to: folder.appending(path: "gary.d.ts"))
        let tsconfig = PluginScaffold.files(id: PluginID("you.examples")!, kinds: [.service])["tsconfig.json"]!
        try Data(tsconfig.utf8).write(to: folder.appending(path: "tsconfig.json"))
        var files = Capability.all.map { "\($0.name).ts" }
        for capability in Capability.all { try Data(capability.example.utf8).write(to: folder.appending(path: "\(capability.name).ts")) }
        let builtins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/plugins").standardizedFileURL
        for plugin in try FileManager.default.contentsOfDirectory(atPath: builtins.path) {
            for entry in try FileManager.default.contentsOfDirectory(atPath: builtins.appending(path: plugin).path) where entry.hasSuffix(".ts") {
                files.append("builtin-\(plugin)-\(entry)")
                try FileManager.default.copyItem(at: builtins.appending(path: "\(plugin)/\(entry)"), to: folder.appending(path: files.last!))
            }
        }
        let check = Process()
        check.executableURL = deno
        check.currentDirectoryURL = folder
        check.arguments = ["check", "--quiet", "--config", "tsconfig.json", "gary.d.ts"] + files
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check.waitUntilExit()
        #expect(check.terminationStatus == 0, "\(text)")
    }

    @Test func documentsEveryPermissionCommandManifestFieldKindNodeAndLayer() throws {
        let guide = guide
        for permission in Permission.allCases { #expect(guide.contains("| `\(permission.rawValue)` | \(permission.name) |")) }
        for (syntax, _, _) in Request.usage + appUsage + skillUsage + pluginUsage { #expect(guide.contains("`gary \(syntax)`"), "\(syntax)") }
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
