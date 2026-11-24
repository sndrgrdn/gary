import Foundation
@testable import gary
import GaryCore
import Testing

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var second = 0

    func read() -> Int {
        lock.withLock { second }
    }

    func set(_ value: Int) {
        lock.withLock { second = value }
    }
}

struct PluginMetricsTests {
    @Test func `timer fires, live timers, renders and the last tree size are counted`() async throws {
        let harness = try Harness("""
        var count = 0;
        var ticking = setInterval(function () { count += 1; }, 100);
        setTimeout(function () {}, 5000);
        export default {
          render: function () { return { type: "row", children: [{ type: "text", text: String(count) }, { type: "spacer" }] }; },
          onAction: function () { clearInterval(ticking); return true; },
        };
        """)
        _ = await harness.events.next()
        harness.timers.advance(by: 1000)
        await harness.settled()
        var stats = harness.runtime.metrics.snapshot
        #expect(stats.timerFiresPerMinute == 10)
        #expect(stats.entries[.timer] == 10)
        #expect(stats.intervals == 1 && stats.timeouts == 1)
        #expect(stats.renders == 11)
        #expect(stats.lastRenderNodes == 3)
        harness.timers.advance(by: 4000)
        await harness.settled()
        stats = harness.runtime.metrics.snapshot
        #expect(stats.timerFiresPerMinute == 51)
        #expect(stats.intervals == 1 && stats.timeouts == 0)
        harness.runtime.perform("stop", .null)
        await harness.settled()
        stats = harness.runtime.metrics.snapshot
        #expect(stats.entries[.action] == 1)
        #expect(stats.intervals == 0)
        harness.runtime.stop()
    }

    @Test func `a tree over the node cap is refused, counted, and the last tree stays until a smaller one comes`() async throws {
        let harness = try Harness("""
        var count = 0;
        export default {
          render: function () {
            if (count !== 1) return { type: "text", text: String(count) };
            return { type: "row", children: Array.from({ length: \(Node.maxNodes) }, function (_, i) { return { type: "text", text: String(i) }; }) };
          },
          onAction: function () { count += 1; return true; },
        };
        """)
        #expect(try await harness.text() == "0")
        harness.runtime.perform("next", .null)
        await harness.settled()
        #expect(harness.events.isEmpty)
        var stats = harness.runtime.metrics.snapshot
        #expect(stats.refusedRenders == 1)
        #expect(stats.lastRenderNodes == 1)
        harness.runtime.perform("next", .null)
        #expect(try await harness.text() == "2")
        stats = harness.runtime.metrics.snapshot
        #expect(stats.refusedRenders == 1)
        #expect(stats.lastRenderNodes == 1)
        harness.runtime.stop()
    }

    @Test func `a host call is pending until it settles, and its settling is a host entry`() async throws {
        let harness = try Harness(
            widget("""
            onAction: function (name) {
              if (name === "exec") host.exec(["/bin/sleep", "30"]);
              else host.call("answer").then(function () { count = "done"; });
            },
            """),
            uses: ["exec"],
        )
        _ = try await harness.text()
        harness.runtime.perform("exec", .null)
        harness.runtime.perform("call", .null)
        guard case let .call(_, _, _, reply) = await harness.events.next() else { throw RenderError("expected a call") }
        #expect(harness.runtime.metrics.snapshot.pendingHostCalls == ["host.exec": 1, "host.call": 1])
        reply(.ok("1"))
        #expect(try await harness.text() == "done")
        let stats = harness.runtime.metrics.snapshot
        #expect(stats.pendingHostCalls == ["host.exec": 1])
        #expect(stats.entries[.host] == 1)
        harness.runtime.stop()
    }

    @Test func `the last 60 seconds drop older CPU time and timer fires but the total keeps them`() {
        let clock = FakeClock()
        let metrics = PluginMetrics(clock: clock.read)
        metrics.entered(.render, spent: .milliseconds(7), stopped: false)
        for _ in 1...3 {
            metrics.entered(.timer, spent: .zero, stopped: false)
        }
        clock.set(30)
        metrics.entered(.timer, spent: .milliseconds(5), stopped: false)
        metrics.entered(.timer, spent: .zero, stopped: false)
        clock.set(61)
        metrics.entered(.timer, spent: .zero, stopped: false)
        var stats = metrics.snapshot
        #expect(stats.cpu == .milliseconds(12))
        #expect(stats.recentCPU == .milliseconds(5))
        #expect(stats.timerFiresPerMinute == 3)
        clock.set(90)
        metrics.entered(.timer, spent: .zero, stopped: false)
        stats = metrics.snapshot
        #expect(stats.recentCPU == .zero)
        #expect(stats.timerFiresPerMinute == 2)
    }

    @Test func `a plugin with two entries over 16 ms in a minute is reported busy though its CPU stays low`() {
        let clock = FakeClock()
        let metrics = PluginMetrics(clock: clock.read)
        let reports = Counter()
        metrics.whenBusy { reports.add() }
        metrics.entered(.timer, spent: .milliseconds(80), stopped: false)
        metrics.entered(.timer, spent: .milliseconds(16), stopped: false)
        clock.set(61)
        metrics.entered(.timer, spent: .milliseconds(80), stopped: false)
        #expect(reports.total == 0)
        #expect(metrics.snapshot.recentSlowEntries == 1)
        clock.set(91)
        metrics.entered(.timer, spent: .milliseconds(80), stopped: false)
        #expect(reports.total == 1)
        #expect(metrics.snapshot.recentSlowEntries == 2)
        #expect(metrics.snapshot.recentCPU == .milliseconds(160))
    }
}
