import Foundation
@testable import GaryCore
import Testing

struct PluginTypesTests {
    private let theme: JSON

    init() throws {
        theme = try JSON.parse(#"{"styles": {"default": {}, "title": {}}, "fonts": {"body": {}}, "colors": {"accent": "accent"}}"#)
    }

    @Test func `declares every node kind style prop kind layer and gesture the runtime parses`() {
        let text = PluginTypes.declarations(capabilities: [], topics: [], published: "Json", theme: nil)
        for kind in Node.Kind.allCases {
            #expect(text.contains("type: \"\(kind.rawValue)\";"))
        }
        for (name, _) in StyleProps.numbers {
            #expect(text.contains("\(name)?: number;"))
        }
        for (name, _) in StyleProps.colors {
            #expect(text.contains("\(name)?: Color;"))
        }
        for (name, _) in StyleProps.signed {
            #expect(text.contains("\(name)?: number;"))
        }
        #expect(text.contains("background?: Paint;"))
        #expect(text.contains("blend?: " + Blend.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | ") + ";"))
        for property in Loop.Property.allCases {
            #expect(text.contains("\(property.rawValue)?: [number, number];"))
        }
        #expect(text.contains("type Paint = Color | { gradient: \"linear\" | \"radial\" | \"angular\";"))
        for kind in PluginKind.allCases {
            #expect(text.contains("type \(PluginTypes.typeName(kind.rawValue)) = "))
        }
        for layer in SurfaceLayer.allCases {
            #expect(text.contains("\"\(layer.rawValue)\""))
        }
        for field in Node.Gesture.allCases.map(\.rawValue) + ["tooltip"] {
            #expect(text.contains("\(field)?: string;"))
        }
    }

    @Test func `declares named surfaces the rendered surface and host surface names`() {
        let text = PluginTypes.declarations(capabilities: [], topics: [], published: "Json", theme: nil)
        #expect(text.contains("surfaces?: { [name: string]: SurfaceExport };"))
        #expect(text.contains("surface?: string;"))
        for request in ["show", "hide", "toggle"] {
            #expect(text.contains("\(request)(surface?: string): void;"))
        }
    }

    @Test func `adds capability declarations topic types the published type and theme names`() throws {
        let text = try PluginTypes.declarations(
            capabilities: ["declare namespace Gary { interface Clock { epoch: number } }"],
            topics: [.init(.capability("clock"), "Clock"), .init(.plugin(#require(PluginID("acme.counter"))), "Json")],
            published: #"import("./topic").Topic"#,
            theme: theme,
        )
        #expect(text.hasSuffix("declare namespace Gary { interface Clock { epoch: number } }\n"))
        #expect(text.contains("    \"clock\": Clock;\n    \"acme.counter\": Json;\n"))
        #expect(text.contains(#"publish(value: import("./topic").Topic): void;"#))
        #expect(text.contains("type StyleName = \"default\" | \"title\" | (string & {});"))
        #expect(text.contains("type FontName = \"body\" | (string & {});"))
        #expect(text.contains("type ColorName = \"accent\" | (string & {});"))
    }

    @Test func `the manifest schema lists the registered capabilities and kinds`() throws {
        let schema = PluginTypes.manifestSchema(makeTestCapabilities())
        let properties = try #require(schema["properties"])
        #expect(properties["uses"]?["items"]?["enum"] ==
            .array(["apps", "audio", "exec", "files", "hotkeys", "mediakeys", "network"].map(JSON.string)))
        let topics = try #require(properties["subscribes"]?["anyOf"]?.array)
        #expect(topics[0]["items"]?["anyOf"]?.array?.first?["enum"] == .array(["apps", "audio", "battery", "clock", "session"].map(JSON.string)))
        #expect(topics[1]["additionalProperties"] == topics[0])
        #expect(properties["kinds"]?["items"]?["enum"] == .array(PluginKind.allCases.map { .string($0.rawValue) }))
        #expect(properties["mediakeys"]?["additionalProperties"]?["items"]?["enum"] == .array(MediaKey.allCases.map { .string($0.rawValue) }))
        #expect(properties["schemaVersion"]?["const"] == .number(Double(PluginManifest.schemaVersion)))
    }

    @Test func `the manifest schema accepts the hotkeys the parser accepts and rejects the ones it rejects`() throws {
        let keys = PluginTypes.manifestSchema(makeTestCapabilities())["properties"]?["hotkeys"]?["items"]?["properties"]?["keys"]
        let pattern = try NSRegularExpression(pattern: #require(keys?["pattern"]?.string))
        let matches = { (text: String) in pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        let valid = [
            "ctrl+alt+space", "Cmd+Shift+F", "hyper+shift+m", "ctrl + a", "f5", "F12", "f13", "f20", "shift+f13", "cmd+backspace",
            "cmd+delete", "alt+pagedown", "control+return", "opt+esc", "command+\\", "ctrl+.", "ctrl+[", "alt+/", "ctrl+`",
        ]
        for text in valid {
            #expect(matches(text) && KeyCombo.parse(text) != nil, "\(text)")
        }
        for text in [
            "shift+a",
            "a",
            "space",
            "f21",
            "f0",
            "ctrl+",
            "meh+a",
            "ctrl+alt+spacebar",
            "cmd++",
            "ctrl+a+b",
            "shift+f",
            "\nctrl+a",
            "ctrl\n+a",
        ] {
            #expect(!matches(text) && KeyCombo.parse(text) == nil, "\(text)")
        }
    }
}

struct PluginScaffoldTests {
    @Test func `the effect version that scaffolds pin is the one Gary bundles`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../package.json")
        let package = try JSON.parse(Data(contentsOf: root))
        #expect(package["devDependencies"]?["effect"] == .string(PluginTypes.effectVersion))
    }

    @Test func `every scaffold passes the load time checks`() throws {
        let capabilities = makeTestCapabilities()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gary-scaffold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for kinds in PluginKind.allCases.map({ [$0] }) + [[.service, .barWidget], [.panel, .service]] {
            let directory = root.appendingPathComponent(kinds.map(\.rawValue).joined(separator: "+"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = try #require(PluginID("acme.hello-world"))
            for (name, text) in PluginScaffold.files(id: id, kinds: kinds) {
                try Data(text.utf8).write(to: directory.appendingPathComponent(name))
            }
            let bundle = try PluginBundle.load(directory, origin: .user, capabilities: capabilities)
            #expect(bundle.manifest.id == id)
            #expect(bundle.manifest.name == "Hello World")
            #expect(bundle.manifest.kinds == kinds)
            for kind in kinds {
                #expect(try bundle.entryPoint(kind) == PluginScaffold.entryFile(kind))
            }
        }
    }
}

struct ExamplePluginTests {
    @Test func `every example passes the load time checks`() throws {
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../examples").standardizedFileURL
        let directories = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath)
        #expect(directories.count >= 3)
        let capabilities = makeTestCapabilities()
        for directory in directories {
            #expect(throws: Never.self, "\(directory.lastPathComponent)") { try PluginBundle.load(
                directory,
                origin: .user,
                capabilities: capabilities,
            ) }
        }
    }
}

struct TopicImportTests {
    @Test func `a topic import is relative to the consumer folder`() {
        let root = URL(fileURLWithPath: "/plugins")
        func path(_ from: URL, _ to: URL) -> String {
            PluginTypes.topicImport(from: from, to: to)
        }
        #expect(path(root.appending(path: "you.front"), root.appending(path: "you.dinky")) == #"import("../you.dinky/topic").Topic"#)
        #expect(path(root.appending(path: "you.theme"), root.appending(path: "you.theme")) == #"import("./topic").Topic"#)
        #expect(path(root.appending(path: "a/b"), URL(fileURLWithPath: "/pkg/c")) == #"import("../../../pkg/c/topic").Topic"#)
    }
}
