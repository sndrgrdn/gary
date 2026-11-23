import Foundation
@testable import gary
import GaryCore
import Testing

private let stopped = "stopped after running longer than 100 ms"
private let spin = "function spin(ms) { var end = Date.now() + ms; while (Date.now() < end) {} }"

struct PluginEngineTests {
    @Test func `a runaway is stopped after 100 ms and only its own plugin fails`() async throws {
        let engine = PluginEngine()
        let bystander = try Harness(widget("onAction: function () { count += 1; return true; },"), id: "test.bystander", engine: engine)
        let runaway = try Harness(widget("onAction: function () { for (;;) {} },"), id: "test.runaway", engine: engine)
        #expect(try await bystander.text() == "0")
        #expect(try await runaway.text() == "0")
        let started = ContinuousClock.now
        runaway.runtime.perform("spin", .null)
        #expect(try await runaway.failure() == stopped)
        #expect(started.duration(to: .now) >= .milliseconds(100))
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
        let panel = engines.engine(for: .panel)
        nonisolated(unsafe) let context = try #require(panel.makeContext())
        let id = try #require(PluginID("test.panel"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = try? panel.run(id, in: context) {
                entered.signal()
                release.wait()
                return nil
            }
        }
        await withCheckedContinuation { done in DispatchQueue.global().async { entered.wait(); done.resume() } }
        let bar = try Harness(widget("onAction: function () { count += 1; return true; },"), id: "test.bar", engine: engines.engine(for: .barWidget))
        #expect(try await bar.text() == "0")
        bar.runtime.perform("tick", .null)
        #expect(try await bar.text() == "1")
        bar.runtime.stop()
    }

    @Test func `time a script spends asleep in a host call does not count toward its limit`() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "gary-effect-\(UUID().uuidString).js")
        try Data("\(spin) spin(70); var GaryEffect = { forPlugin: function () {} };".utf8).write(to: library)
        defer { try? FileManager.default.removeItem(at: library) }
        let engine = PluginEngine(effect: library)
        let context = try #require(engine.makeContext())
        let load: @convention(block) () -> Void = { _ = try? engine.effect() }
        let sleep: @convention(block) () -> Void = { Thread.sleep(forTimeInterval: 0.15) }
        context.setObject(load, forKeyedSubscript: "load" as NSString)
        context.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
        let value = try engine.run(#require(PluginID("test.sleeper")), in: context) {
            context.evaluateScript("\(spin) load(); sleep(); spin(40); 1")
        }
        #expect(value?.toInt32() == 1)
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
