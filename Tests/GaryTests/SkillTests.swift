import Foundation
@testable import gary
import GaryCore
import Testing

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardizedFileURL

struct SkillTests {
    private var guide: String {
        get throws {
            try Skill.guide(
                theme: JSON.parse(#"{"styles": {"panel": {"radius": 12}}, "colors": {"accent": "accent"}, "fonts": {"body": {"size": 12}}}"#),
                examples: [BundledExample(name: "load", summary: "A bar widget that shows the load.", manifest: nil)],
            )
        }
    }

    @Test func `documents every capability with its manifest entry permissions and declarations`() throws {
        let guide = try guide
        for capability in Capability.all {
            #expect(guide.contains("### \(capability.name)\n\n\(capability.summary)"), "\(capability.name)")
            #expect(guide.contains(capability.types.trimmingCharacters(in: .newlines)), "\(capability.name)")
            #expect(guide.contains("\"uses\": [\"\(capability.name)\"]") == (capability.install != nil), "\(capability.name)")
            #expect(guide.contains("\"subscribes\": [\"\(capability.name)\"]") == (capability.topic != nil), "\(capability.name)")
            for permission in capability
                .permissions
            {
                #expect(guide.contains("\(permission.name) (`\(permission.rawValue)`)"), "\(capability.name)")
            }
        }
    }

    @Test func `shows an example entry file for every capability`() throws {
        let guide = try guide
        for capability in Capability.all {
            #expect(capability.example.contains("export default {") && capability.example.contains("} satisfies Gary."), "\(capability.name)")
            #expect(guide.contains("```ts\n\(capability.example.trimmingCharacters(in: .newlines))\n```"), "\(capability.name)")
        }
    }

    @Test func `every capability example and built in plugin type checks`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gary-examples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let declarations = PluginTypes.declarations(
            capabilities: Capability.all.map(\.types),
            topics: Capability.all.compactMap { capability in capability.topic.map { PluginTypes.TopicType(.capability(capability.name), $0.type) } },
            published: "Json",
            theme: nil,
        )
        try Data(declarations.utf8).write(to: folder.appending(path: "gary.d.ts"))
        let id = try #require(PluginID("you.examples"))
        let tsconfig = try #require(PluginScaffold.files(id: id, kinds: [.service])["tsconfig.json"])
        try Data(tsconfig.utf8).write(to: folder.appending(path: "tsconfig.json"))
        for capability in Capability.all {
            try Data(capability.example.utf8).write(to: folder.appending(path: "\(capability.name).ts"))
        }
        let builtins = root.appending(path: "Resources/plugins")
        for plugin in try FileManager.default.contentsOfDirectory(atPath: builtins.path) {
            for entry in try FileManager.default.contentsOfDirectory(atPath: builtins.appending(path: plugin).path)
                where entry.hasSuffix(".ts") && entry != PluginTypes.declarationsFile
            {
                try FileManager.default.copyItem(
                    at: builtins.appending(path: "\(plugin)/\(entry)"),
                    to: folder.appending(path: "builtin-\(plugin)-\(entry)"),
                )
            }
        }
        let check = Process()
        check.executableURL = root.appending(path: "node_modules/.bin/tsc")
        check.currentDirectoryURL = folder
        check.arguments = ["-p", "."]
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check.waitUntilExit()
        #expect(check.terminationStatus == 0, "\(text)")
    }

    @Test func `documents every permission command manifest field kind node and layer`() throws {
        let guide = try guide
        for permission in Permission.allCases {
            #expect(guide.contains("| `\(permission.rawValue)` | \(permission.name) |"))
        }
        for usage in Request.usage + appUsage + skillUsage + pluginUsage {
            #expect(guide.contains("`gary \(usage.syntax)`"), "\(usage.syntax)")
        }
        let fields = try #require(try PluginTypes.manifestSchema(Capability.names())["properties"]?.object).keys
        for field in fields {
            #expect(guide.contains("`\(field)`"), "\(field)")
        }
        for kind in PluginKind.allCases {
            #expect(guide.contains("| `\(kind.rawValue)` |"))
        }
        for kind in Node.Kind.allCases {
            #expect(guide.contains("`\(kind.rawValue)`"))
        }
        for layer in SurfaceLayer.allCases {
            #expect(guide.contains("`\(layer.rawValue)`"))
        }
    }

    @Test func `lists the theme and the bundled examples`() throws {
        let guide = try guide
        #expect(guide.contains("- `panel`: `{\"radius\":12}`"))
        #expect(guide.contains("- `accent`: `\"accent\"`"))
        #expect(guide.contains("type StyleName = \"panel\""))
        #expect(guide.contains("- `load`. A bar widget that shows the load."))
    }
}
