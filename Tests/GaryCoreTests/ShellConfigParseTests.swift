import Foundation
@testable import GaryCore
import Testing

struct ShellConfigParseTests {
    @Test func `each section reports its own path`() {
        let cases: [(String, ShellConfigError)] = [
            (#"{"settings": []}"#, ShellConfigError(path: "settings", reason: "must be an object keyed by plugin id")),
            (#"{"plugins": ["acme.a", 3]}"#, ShellConfigError(path: "plugins[1]", reason: "is not a plugin id")),
            (#"{"bar": {"right": "gary.clock"}}"#, ShellConfigError(path: "bar.right", reason: "must be an array of plugin ids")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try ShellConfig.parse(JSON.parse(text)) }
        }
    }

    @Test func `a bar with sections and reveal sets both and fills missing sections`() throws {
        let parsed = try ShellConfig.parse(JSON.parse(#"{"bar": {"center": ["acme.a"], "revealMenuBar": false}, "disabledPlugins": ["acme.b"]}"#))
        let id = try #require(PluginID("acme.a"))
        #expect(parsed.bar == [.left: [], .center: [id], .right: []])
        #expect(!parsed.revealMenuBar)
        #expect(parsed.disabledPlugins == Set(["acme.b"].compactMap(PluginID.init)))
    }
}
