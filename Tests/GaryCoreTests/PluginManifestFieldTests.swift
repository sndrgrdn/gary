import Foundation
@testable import GaryCore
import Testing

struct PluginManifestFieldTests {
    private func parse(_ extra: String) throws -> PluginManifest {
        let base = #"{"schemaVersion":1,"id":"acme.media","name":"Media","version":"1","kinds":["panel"],"entryPoints":{"panel":"p.js"}}"#
        guard case var .object(fields) = try JSON.parse(base), case let .object(overrides) = try JSON.parse(extra) else {
            throw JSON.ParseError(description: "not an object")
        }
        fields.merge(overrides) { $1 }
        return try PluginManifest.parse(JSON.object(fields).encoded(), origin: .user, capabilities: makeTestCapabilities())
    }

    @Test func `a field of the wrong shape names the field`() {
        let cases: [(String, ManifestError)] = [
            (#"{"kinds":["panel",1]}"#, .wrongType("kinds")),
            (#"{"entryPoints":{"panel":1}}"#, .wrongType("entryPoints.panel")),
            (#"{"keepLoaded":"yes"}"#, .wrongType("keepLoaded")),
            (#"{"keepLoaded":null}"#, .wrongType("keepLoaded")),
            (#"{"subscribes":"clock"}"#, .wrongType("subscribes")),
            (#"{"uses":["exec",2]}"#, .wrongType("uses")),
            (#"{"hotkeys":{}}"#, .wrongType("hotkeys")),
            (#"{"hotkeys":[{"id":"","keys":"ctrl+a"}]}"#, .wrongType("hotkeys[0]")),
        ]
        for (extra, error) in cases {
            #expect(throws: error, "\(extra)") { try parse(extra) }
        }
    }

    @Test func `subscriptions keep their order and split capabilities from plugins`() throws {
        let parsed = try parse(#"{"subscribes":["acme.counter","clock"],"keepLoaded":true}"#)
        let counter = try #require(PluginID("acme.counter"))
        #expect(parsed.subscriptions == [.panel: [.plugin(counter), .capability("clock")]])
        #expect(parsed.keepLoaded)
        #expect(parsed.hotkeys.isEmpty)
    }
}
