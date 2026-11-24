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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var total: Int {
        lock.withLock { value }
    }

    func add() {
        lock.withLock { value += 1 }
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
        let slowID = try #require(PluginID("test.slow"))
        let healthyID = try #require(PluginID("test.healthy"))
        let metrics = PluginMetrics()
        for _ in 1...10 {
            #expect(try engine.run(slowID, in: slow, .action, into: metrics) { slow.evaluateScript("burn(70); 1") }?.toInt32() == 1)
            #expect(try engine.run(healthyID, in: healthy, .action, into: metrics) { healthy.evaluateScript("burn(40); 1") }?.toInt32() == 1)
        }
        let error = #expect(throws: RenderError.self) {
            try engine.run(slowID, in: slow, .action, into: metrics) { slow.evaluateScript("burn(70); burn(40); 1") }
        }
        #expect(error?.description == stopped)
    }

    @Test func `each entry's CPU time is counted by cause, with the longest entry and the entries stopped at the limit`() throws {
        let cpu = FakeCPU()
        let engine = PluginEngine(cpuTime: cpu.read)
        let context = try burning(cpu, engine)
        let id = try #require(PluginID("test.counted"))
        let metrics = PluginMetrics()
        _ = try engine.run(id, in: context, .render, into: metrics) { context.evaluateScript("burn(30); 1") }
        _ = try engine.run(id, in: context, .timer, into: metrics) { context.evaluateScript("burn(50); 1") }
        _ = try? engine.run(id, in: context, .action, into: metrics) { context.evaluateScript("burn(70); burn(40); 1") }
        let stats = metrics.snapshot
        #expect(stats.cpu == .milliseconds(190))
        #expect(stats.recentCPU == .milliseconds(190))
        #expect(stats.longestEntry == .milliseconds(110))
        #expect(stats.overTimeLimit == 1)
        #expect(stats.entries == [.load: 0, .render: 1, .timer: 1, .topic: 0, .action: 1, .call: 0, .host: 0])
    }

    @MainActor @Test func `a bar widget does not wait for a panel's long call`() async throws {
        let engines = PluginEngines()
        let panel = try engines.engine(for: SlotKey(id: #require(PluginID("test.panel")), kind: .panel))
        nonisolated(unsafe) let context = try #require(panel.makeContext())
        let id = try #require(PluginID("test.panel"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = try? panel.run(id, in: context, .call, into: PluginMetrics()) {
                entered.signal()
                release.wait()
                return nil
            }
        }
        await withCheckedContinuation { done in DispatchQueue.global().async { entered.wait(); done.resume() } }
        let bar = try Harness(
            widget("onAction: function () { count += 1; return true; },"),
            id: "test.bar",
            engine: engines.engine(for: SlotKey(id: #require(PluginID("test.bar")), kind: .barWidget)),
        )
        #expect(try await bar.text() == "0")
        bar.runtime.perform("tick", .null)
        #expect(try await bar.text() == "1")
        bar.runtime.stop()
    }

    @MainActor @Test func `a promoted plugin loads on its own engine while the other bar plugins keep sharing one`() throws {
        let engines = PluginEngines()
        let busy = try SlotKey(id: #require(PluginID("test.busy")), kind: .barWidget)
        let clock = try SlotKey(id: #require(PluginID("test.clock")), kind: .barWidget)
        let battery = try SlotKey(id: #require(PluginID("test.battery")), kind: .barWidget)
        #expect(engines.engine(for: busy) === engines.engine(for: clock))
        #expect(engines.promote(busy))
        #expect(!engines.promote(busy))
        let own = engines.engine(for: busy)
        #expect(own.name == "own")
        #expect(own !== engines.engine(for: clock))
        #expect(engines.engine(for: clock) === engines.engine(for: battery))
        #expect(engines.engine(for: clock).name == "bar")
    }

    @Test func `a plugin that spends over a second of CPU in a minute is reported busy once`() throws {
        let cpu = FakeCPU()
        let engine = PluginEngine(cpuTime: cpu.read)
        let context = try burning(cpu, engine)
        let id = try #require(PluginID("test.busy"))
        let metrics = PluginMetrics()
        let reports = Counter()
        metrics.whenBusy { reports.add() }
        for _ in 1...5 {
            _ = try engine.run(id, in: context, .timer, into: metrics) { context.evaluateScript("burn(16); 1") }
        }
        #expect(reports.total == 0)
        for _ in 1...60 {
            _ = try engine.run(id, in: context, .timer, into: metrics) { context.evaluateScript("burn(16); 1") }
        }
        #expect(reports.total == 1)
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
