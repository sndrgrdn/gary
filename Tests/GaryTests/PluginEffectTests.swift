import Foundation
@testable import gary
import GaryCore
import Testing

private func ticker(_ id: String, engine: PluginEngine) throws -> Harness {
    try Harness("""
    import { Effect } from "gary:effect";
    let ticks = 0;
    export default {
      effect: Effect.forever(Effect.andThen(Effect.sleep(5), Effect.sync(() => { ticks += 1; }))),
      render: () => ({ type: "text", text: String(ticks) }),
    };
    """, id: id, engine: engine)
}

private func count(_ harness: Harness, reaches target: Int) async throws {
    var ticks = 0
    while ticks < target {
        ticks = try await Int(harness.text()) ?? 0
    }
}

struct PluginEffectTests {
    @Test func `unloading closes the plugin scope, so its fibers stop and their finalizers run`() async throws {
        let harness = try Harness("""
        import { Effect, Schedule, host } from "gary:effect";
        let ticks = 0;
        export default {
          effect: Effect.andThen(Effect.addFinalizer(() => host.publish("effect")), Effect.never),
          onAction() {
            Effect.runFork(Effect.repeat(Effect.sync(() => { ticks += 1; }), Schedule.spaced(5)).pipe(Effect.ensuring(host.publish("action"))));
          },
          render: () => ({ type: "text", text: String(ticks) }),
        };
        """)
        #expect(try await harness.text() == "0")
        let listener = Listener()
        _ = harness.hub.subscribe(listener, to: [.plugin(harness.runtime.id)])
        harness.runtime.perform("start", .null)
        try await count(harness, reaches: 3)
        harness.runtime.stop()
        #expect(harness.runtime.queue.sync { !harness.runtime.isRunning })
        #expect(listener.values.compactMap(\.string).sorted() == ["action", "effect"])
    }

    @Test func `each plugin's fibers run on its own timers, so stopping one leaves the other ticking`() async throws {
        let engine = PluginEngine(effect: vendor.appending(path: "effect.js"))
        let first = try ticker("test.first", engine: engine)
        try await count(first, reaches: 1)
        let second = try ticker("test.second", engine: engine)
        try await count(second, reaches: 1)
        first.runtime.stop()
        try await count(second, reaches: 10)
        second.runtime.stop()
    }

    @Test func `a plugin that does not import gary:effect never loads it`() async throws {
        let engine = PluginEngine(effect: URL(fileURLWithPath: "/nonexistent/effect.js"))
        let plain = try Harness(widget(), id: "test.plain", engine: engine)
        #expect(try await plain.text() == "0")
        plain.runtime.stop()
        let importing = try Harness(widget(setup: "import { Effect } from \"gary:effect\";"), id: "test.importing", engine: engine)
        #expect(try await importing.failure().hasPrefix("Error: cannot load gary:effect from /nonexistent/effect.js"))
    }

    @Test func `a topic stream delivers each value of a subscribed topic`() async throws {
        let harness = try Harness("""
        import { Effect, Stream, topic } from "gary:effect";
        const seen = [];
        export default {
          effect: Stream.runForEach(topic("test.source"), (value) => Effect.sync(() => { seen.push(value.n); })),
          render: () => ({ type: "text", text: seen.join(",") }),
        };
        """, subscribes: ["test.source"])
        #expect(try await harness.text().isEmpty)
        let source = try #require(PluginID("test.source"))
        for value in 1...2 {
            harness.hub.publish(.plugin(source), .object(["n": .number(Double(value))]), Trace("test"))
        }
        var text = ""
        while text != "1,2" {
            text = try await harness.text()
        }
        harness.runtime.stop()
    }

    @Test func `an effect that dies fails the plugin`() async throws {
        let harness = try Harness("""
        import { Effect } from "gary:effect";
        export default {
          effect: Effect.andThen(Effect.sleep(1), Effect.die(new Error("boom"))),
          render: () => ({ type: "text", text: "up" }),
        };
        """)
        #expect(try await harness.text() == "up")
        let reason = try await harness.failure()
        #expect(reason.hasPrefix("Error: the effect stopped: Error: boom"))
    }
}
