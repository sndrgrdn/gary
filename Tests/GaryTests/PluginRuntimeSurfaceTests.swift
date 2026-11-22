import Foundation
@testable import gary
import GaryCore
import Testing

func names(_ values: String...) -> JSON {
    .array(values.map(JSON.string))
}

struct PluginRuntimeSurfaceTests {
    @Test func `surfaces resolve their spec from the module`() async throws {
        let harness = try Harness(widget("surface: function (state) { return { width: 300, height: 200 }; },"), kind: .panel)
        guard case let .loaded(output, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(output.surfaces[SurfaceAddress.main]?.width == .points(300))
        #expect(output.trees.mapValues { $0.keys.sorted() } == [SurfaceAddress.main: [display.id]])
        harness.runtime.stop()
    }

    @Test func `each shown surface renders its own trees with its name in the state`() async throws {
        let harness = try Harness("""
        export default {
          surfaces: {
            main: { width: 300, height: 200 },
            osd: function (state) { return { anchors: { bottom: true }, margins: state.settings.greeting === "hi" ? 80 : 0, clickThrough: true }; },
            idle: null,
          },
          render: function (state) { return { type: "text", text: state.surface + " on " + state.display.id }; },
        };
        """, kind: .panel, shown: ["main", "osd"], manifest: ["surfaces": .object(["panel": names("main", "osd", "idle")])])
        guard case let .loaded(output, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(output.surfaces.keys.sorted() == ["main", "osd"])
        #expect(output.surfaces["main"]?.width == .points(300))
        #expect(output.surfaces["osd"]?.margins.bottom == 80 && output.surfaces["osd"]?.clickThrough == true)
        let texts = output.trees.mapValues { trees in trees.mapValues { node -> String in
            if case let .text(text) = node.content {
                text
            } else {
                ""
            }
        } }
        #expect(texts == ["main": [display.id: "main on main"], "osd": [display.id: "osd on main"]])
        harness.runtime.stop()
    }

    @Test func `a module that exports surface and surfaces fails to load`() async throws {
        let harness = try Harness(widget("surface: {}, surfaces: { osd: {} },"), kind: .panel)
        #expect(try await harness.failure() == "surfaces: cannot be exported with surface; put that surface in surfaces as main")
    }

    @Test func `a module whose surface names differ from the manifest fails to load`() async throws {
        let harness = try Harness(widget("surfaces: { main: {}, osd: {} },"), kind: .panel)
        #expect(try await harness
            .failure() == "the module exports surfaces main, osd, but manifest.json gives the panel main; list its surface names in surfaces.panel")
    }

    @Test func `host surface requests name a surface and throw for a name the manifest does not list`() async throws {
        let harness = try Harness(widget("""
        onAction: function (name) {
          try { if (name === "default") host.show(); else host.toggle(name); } catch (e) { count = e.message; }
        },
        """), manifest: [
            "kinds": names("bar-widget", "panel", "overlay"),
            "entryPoints": .object(["bar-widget": .string("main.js"), "panel": .string("main.js"), "overlay": .string("main.js")]),
            "surfaces": .object(["overlay": names("osd")]),
        ])
        #expect(try await harness.text() == "0")
        func next() async throws -> (SurfaceRequest, String) {
            guard case let .surface(request, surface, _) = try await harness.events.next() else { throw RenderError("expected a surface request") }
            return (request, surface)
        }
        harness.runtime.perform("osd", .null)
        #expect(try await next() == (.toggle, "osd"))
        harness.runtime.perform("default", .null)
        #expect(try await next() == (.show, "main"))
        harness.runtime.perform("nope", .null)
        #expect(try await harness.text() == "host.toggle: no surface nope; this plugin declares main, osd")
        harness.runtime.perform("Osd", .null)
        #expect(try await harness.text() == "host.toggle: Osd is not a surface name; use lowercase letters, digits and hyphens")
        harness.runtime.stop()
    }
}
