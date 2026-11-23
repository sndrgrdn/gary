import Foundation
@testable import gary
import GaryCore
import JavaScriptCore
import Testing

private let stopped = "stopped after running longer than 100 ms"

private final class FakeCPU: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Duration.zero

    func read() -> Duration {
        lock.withLock { now }
    }

    func burn(_ milliseconds: Int) {
        lock.withLock { now += .milliseconds(milliseconds) }
    }
}

private func burning(_ cpu: FakeCPU, _ engine: PluginEngine) throws -> JSContext {
    let context = try #require(engine.makeContext())
    let burn: @convention(block) (Int) -> Void = { milliseconds in
        cpu.burn(milliseconds)
        _ = engine.shouldStop(context.jsGlobalContextRef)
    }
    context.setObject(burn, forKeyedSubscript: "burn" as NSString)
    return context
}

struct PluginEngineTests {
    @Test func `a runaway is stopped and only its own plugin fails`() async throws {
        let engine = PluginEngine()
        let bystander = try Harness(widget("onAction: function () { count += 1; return true; },"), id: "test.bystander", engine: engine)
        let runaway = try Harness(widget("onAction: function () { for (;;) {} },"), id: "test.runaway", engine: engine)
        #expect(try await bystander.text() == "0")
        #expect(try await runaway.text() == "0")
        runaway.runtime.perform("spin", .null)
        #expect(try await runaway.failure() == stopped)
        bystander.runtime.perform("tick", .null)
        #expect(try await bystander.text() == "1")
        bystander.runtime.stop()
    }

    @Test func `each entry gets its own 100 ms, so plugins taking turns are never stopped`() throws {
        let cpu = FakeCPU()
        let engine = PluginEngine(cpuTime: cpu.read)
        let slow = try burning(cpu, engine)
        let healthy = try burning(cpu, engine)
        for _ in 1...10 {
            #expect(try engine.run(#require(PluginID("test.slow")), in: slow) { slow.evaluateScript("burn(70); 1") }?.toInt32() == 1)
            #expect(try engine.run(#require(PluginID("test.healthy")), in: healthy) { healthy.evaluateScript("burn(40); 1") }?.toInt32() == 1)
        }
        let error = #expect(throws: RenderError.self) {
            try engine.run(#require(PluginID("test.slow")), in: slow) { slow.evaluateScript("burn(70); burn(40); 1") }
        }
        #expect(error?.description == stopped)
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

    @Test func `a runaway after the last loaded plugin unloads is stopped`() async throws {
        let engine = PluginEngine()
        let runaway = try Harness(widget("onAction: function () { for (;;) {} },"), id: "test.first", engine: engine)
        #expect(try await runaway.text() == "0")
        do {
            let last = try Harness(widget(), id: "test.last", engine: engine)
            #expect(try await last.text() == "0")
            last.runtime.stop()
            #expect(!last.isRunning)
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
