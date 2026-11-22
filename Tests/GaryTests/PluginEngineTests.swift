import Foundation
@testable import gary
import Testing

private let stopped = "stopped after running longer than 100 ms"
private let spin = "function spin(ms) { var end = Date.now() + ms; while (Date.now() < end) {} }"

struct PluginEngineTests {
    @Test func `a runaway is stopped after about 100 ms and only its own plugin fails`() async throws {
        let engine = PluginEngine()
        let bystander = try Harness(widget("onAction: function () { count += 1; return true; },"), id: "test.bystander", engine: engine)
        let runaway = try Harness(widget("onAction: function () { for (;;) {} },"), id: "test.runaway", engine: engine)
        #expect(try await bystander.text() == "0")
        #expect(try await runaway.text() == "0")
        let started = ContinuousClock.now
        runaway.runtime.perform("spin", .null)
        #expect(try await runaway.failure() == stopped)
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= .milliseconds(100) && elapsed < .milliseconds(500))
        bystander.runtime.perform("tick", .null)
        #expect(try await bystander.text() == "1")
        bystander.runtime.stop()
    }

    @Test func `a healthy plugin is never stopped while another runs`() async throws {
        let engine = PluginEngine()
        let slow = try Harness(widget("onAction: function () { spin(70); count += 1; return true; },", setup: spin), id: "test.slow", engine: engine)
        let healthy = try Harness(
            widget("onAction: function () { spin(40); count += 1; return true; },", setup: spin),
            id: "test.healthy",
            engine: engine,
        )
        #expect(try await slow.text() == "0")
        #expect(try await healthy.text() == "0")
        for _ in 1...10 {
            slow.runtime.perform("slow", .null)
            healthy.runtime.perform("tick", .null)
        }
        for expected in 1...10 {
            #expect(try await healthy.text() == String(expected))
            #expect(try await slow.text() == String(expected))
        }
        slow.runtime.stop()
        healthy.runtime.stop()
    }

    @Test func `a bar widget does not wait for a panel's long call`() async throws {
        let engines = PluginEngines()
        let panel = try Harness(
            widget("surface: { width: 300, height: 200 }, onAction: function () { spin(80); count += 1; return true; },", setup: spin),
            id: "test.panel", kind: .panel, engine: engines.engine(for: .panel),
        )
        let bar = try Harness(widget("onAction: function () { count += 1; return true; },"), id: "test.bar", engine: engines.engine(for: .barWidget))
        #expect(try await panel.text() == "0")
        #expect(try await bar.text() == "0")
        panel.runtime.perform("slow", .null)
        try await Task.sleep(for: .milliseconds(10))
        let started = ContinuousClock.now
        bar.runtime.perform("tick", .null)
        #expect(try await bar.text() == "1")
        #expect(started.duration(to: .now) < .milliseconds(50))
        #expect(try await panel.text() == "1")
        panel.runtime.stop()
        bar.runtime.stop()
    }

    @Test func `a runaway after the last loaded plugin unloads is stopped`() async throws {
        let engine = PluginEngine()
        let runaway = try Harness(widget("onAction: function () { for (;;) {} },"), id: "test.first", engine: engine)
        #expect(try await runaway.text() == "0")
        do {
            let last = try Harness(widget(), id: "test.last", engine: engine)
            #expect(try await last.text() == "0")
            last.runtime.stop()
            #expect(last.runtime.queue.sync { !last.runtime.isRunning })
        }
        runaway.runtime.perform("spin", .null)
        #expect(try await runaway.failure() == stopped)
    }

    @Test func `a runaway promise callback is stopped without failing the next plugin`() async throws {
        let engine = PluginEngine()
        let runaway = try Harness(
            widget("onAction: function () { Promise.resolve().then(function () { for (;;) {} }); return true; },"),
            id: "test.promise", engine: engine,
        )
        let next = try Harness(widget("onAction: function () { count += 1; return true; },"), id: "test.next", engine: engine)
        #expect(try await runaway.text() == "0")
        #expect(try await next.text() == "0")
        runaway.runtime.perform("spin", .null)
        #expect(try await runaway.failure() == stopped)
        next.runtime.perform("tick", .null)
        #expect(try await next.text() == "1")
        next.runtime.stop()
    }
}
