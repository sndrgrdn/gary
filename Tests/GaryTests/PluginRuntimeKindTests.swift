import Foundation
@testable import gary
import GaryCore
import Testing

struct PluginRuntimeKindTests {
    @Test func `host call with a kind target reaches that kind and rejects a kind the plugin lacks`() async throws {
        let harness = try Harness(widget("""
        render: function () { return { type: "text", text: shown }; },
        onAction: function (name) {
          host.call(name === "other" ? { plugin: "you.other" } : { kind: name }, "ping", 3).then(
            function (value) { shown = "ok " + value; },
            function (error) { shown = error.message; }
          );
        },
        """, setup: "var shown = \"start\";"))
        #expect(try await harness.text() == "start")
        harness.runtime.perform("bar-widget", .null)
        guard case let .call(target, method, arguments, reply) = await harness.events.next() else { throw RenderError("expected a call") }
        #expect(target.plugin == nil && target.kind == .barWidget && method == "ping" && arguments == ["3"])
        reply(.ok("4"))
        #expect(try await harness.text() == "ok 4")
        harness.runtime.perform("other", .null)
        guard case let .call(other, _, _, answer) = await harness.events.next() else { throw RenderError("expected a call") }
        #expect(other.plugin == PluginID("you.other"))
        answer(.failure("you.other is not enabled"))
        #expect(try await harness.text() == "you.other is not enabled")
        harness.runtime.perform("panel", .null)
        #expect(try await harness.text() == "host.call: test.runtime has no kind panel")
        harness.runtime.stop()
    }

    @Test func `host call with an invalid plugin id rejects and leaves the engine free`() async throws {
        let harness = try Harness(widget("""
        render: function () { return { type: "text", text: shown }; },
        onAction: function () {
          host.call({ plugin: "nope" }, "ping").then(
            function () { shown = "resolved"; },
            function (error) { shown = error.message; }
          );
        },
        """, setup: "var shown = \"start\";"), engine: PluginEngine(effect: vendor.appending(path: "effect.js")))
        #expect(try await harness.text() == "start")
        harness.runtime.perform("go", .null)
        await harness.settled()
        #expect(try await harness.text() == "host.call: nope is not a plugin id")
        harness.runtime.stop()
    }

    @Test func `host call to another plugin rejects a kind that does not exist`() async throws {
        let harness = try Harness(widget("""
        render: function () { return { type: "text", text: shown }; },
        onAction: function () {
          host.call({ plugin: "you.music", kind: "pannel" }, "ping").then(
            function () { shown = "resolved"; },
            function (error) { shown = error.message; }
          );
        },
        """, setup: "var shown = \"start\";"))
        #expect(try await harness.text() == "start")
        harness.runtime.perform("go", .null)
        #expect(try await harness.text() == "host.call: pannel is not a kind; use bar-widget, bar, panel, overlay, menu, service")
        harness.runtime.stop()
    }

    @Test func `a bar widget that renders null has no tree until it renders a node and a panel that renders null fails`() async throws {
        let source = """
        var count = 0;
        export default {
          render: function () { return count ? { type: "text", text: String(count) } : null; },
          onAction: function () { count += 1; },
        };
        """
        let widget = try Harness(source)
        guard case let .loaded(output, _) = await widget.events.next() else { throw RenderError("expected loaded") }
        #expect(output.trees == [SurfaceAddress.main: [display.id: nil]])
        widget.runtime.perform("add", .null)
        #expect(try await widget.text() == "1")
        widget.runtime.stop()
        let panel = try Harness(source, kind: .panel)
        #expect(try await panel.failure() == "root: node must be an object")
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
