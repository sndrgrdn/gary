import Foundation
@testable import gary
import GaryCore
import Testing

struct PluginRuntimeKindTests {
    @Test func `host call with a kind target reaches that kind and rejects a kind the plugin lacks`() async throws {
        let harness = try Harness(widget("""
        render: function () { return { type: "text", text: shown }; },
        onAction: function (name) {
          host.call({ kind: name }, "ping", 3).then(
            function (value) { shown = "ok " + value; },
            function (error) { shown = error.message; }
          );
        },
        """, setup: "var shown = \"start\";"))
        #expect(try await harness.text() == "start")
        harness.runtime.perform("bar-widget", .null)
        guard case let .call(kind, method, arguments, reply) = try await harness.events.next() else { throw RenderError("expected a call") }
        #expect(kind == .barWidget && method == "ping" && arguments == ["3"])
        reply(.ok("4"))
        #expect(try await harness.text() == "ok 4")
        harness.runtime.perform("panel", .null)
        #expect(try await harness.text() == "host.call: test.runtime has no kind panel")
        harness.runtime.stop()
    }

    @Test func `a kind receives only the topics the manifest lists for it`() async throws {
        let harness = try Harness(widget("""
        onTopic: function (event) { seen.push(event.topic); },
        render: function () { return { type: "text", text: seen.join(",") }; },
        """, setup: "var seen = [];"), manifest: [
            "kinds": names("bar-widget", "panel"),
            "entryPoints": .object(["bar-widget": .string("main.js"), "panel": .string("main.js")]),
            "subscribes": .object(["bar-widget": names("test.mine"), "panel": names("test.other")]),
        ])
        #expect(try await harness.text().isEmpty)
        try harness.hub.publish(.plugin(#require(PluginID("test.other"))), .number(1), Trace("test"))
        try harness.hub.publish(.plugin(#require(PluginID("test.mine"))), .number(2), Trace("test"))
        #expect(try await harness.text() == "test.mine")
        harness.runtime.stop()
    }
}
