import Foundation
@testable import gary
import GaryCore
import Testing

struct PluginRuntimeSurfaceTests {
    @Test func `surfaces resolve their spec from the module`() async throws {
        let harness = try Harness(widget("module.exports.surface = function (state) { return { width: 300, height: 200 }; };"), kind: .panel)
        guard case let .loaded(output, surfaces, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(surfaces == [SurfaceAddress.main])
        #expect(output.surfaces[SurfaceAddress.main]?.width == .points(300))
        #expect(output.trees.mapValues { $0.keys.sorted() } == [SurfaceAddress.main: [display.id]])
        harness.runtime.stop()
    }

    @Test func `each shown surface renders its own trees with its name in the state`() async throws {
        let harness = try Harness("""
        module.exports.surfaces = {
          main: { width: 300, height: 200 },
          osd: function (state) { return { anchors: { bottom: true }, margins: state.settings.greeting === "hi" ? 80 : 0, clickThrough: true }; },
          idle: null,
        };
        module.exports.render = function (state) { return { type: "text", text: state.surface + " on " + state.display.id }; };
        """, kind: .panel, shown: ["main", "osd"])
        guard case let .loaded(output, surfaces, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(surfaces == ["idle", "main", "osd"])
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
        let harness = try Harness(widget("module.exports.surface = {}; module.exports.surfaces = { osd: {} };"), kind: .panel)
        #expect(try await harness.failure() == "surfaces: cannot be exported with surface; put that surface in surfaces as main")
    }

    @Test func `host surface requests name a surface and throw for a name the module does not declare`() async throws {
        let harness = try Harness(widget("""
        module.exports.surfaces = { main: {}, osd: {} };
        module.exports.onAction = function (name) {
          try { if (name === "default") host.show(); else host.toggle(name); } catch (e) { count = e.message; }
        };
        """), kind: .panel)
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
        #expect(try await harness.text() == "host.toggle: no surface nope; this module declares main, osd")
        harness.runtime.perform("Osd", .null)
        #expect(try await harness.text() == "host.toggle: Osd is not a surface name; use lowercase letters, digits and hyphens")
        harness.runtime.stop()
    }
}
