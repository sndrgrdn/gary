import Darwin
import Foundation
@testable import gary
import GaryCore
import os
import Testing

struct SystemTests {
    @Test func `CPU load is each state's share of the ticks since the earlier sample, across A counter wrap`() {
        let earlier = CPUTicks(user: UInt32.max - 9, system: 100, idle: 1000)
        let now = CPUTicks(user: 20, system: 120, idle: 1050)
        #expect(now.load(since: earlier) == CPULoad(user: 0.3, system: 0.2, idle: 0.5))
        #expect(now.load(since: now) == CPULoad(user: 0, system: 0, idle: 1))
    }

    @Test func `memory used counts app wired and compressed pages but not purgeable ones`() {
        var stats = vm_statistics64()
        stats.internal_page_count = 100
        stats.purgeable_count = 20
        stats.wire_count = 30
        stats.compressor_page_count = 10
        stats.free_count = 500
        let memory = MemoryUse(stats, pageSize: 16384, total: 1 << 30, pressureLevel: 2)
        #expect(memory.used == 120 * 16384)
        #expect(memory.total == 1 << 30)
        #expect(memory.pressure == .warning)
        #expect(MemoryUse(stats, pageSize: 16384, total: 1 << 30, pressureLevel: 4).pressure == .critical)
        #expect(MemoryUse(stats, pageSize: 16384, total: 1 << 30, pressureLevel: 1).pressure == .normal)
    }

    @MainActor @Test func `the topic publishes CPU memory and idle time half A second after it starts`() async throws {
        let source = try #require(Capability.system.topic).source
        var feed: TopicFeed?
        let value = await withCheckedContinuation { (done: CheckedContinuation<JSON, Never>) in
            let waiting = OSAllocatedUnfairLock<CheckedContinuation<JSON, Never>?>(initialState: done)
            feed = source { published, _ in
                waiting.withLock { waiting in
                    waiting?.resume(returning: published)
                    waiting = nil
                }
            }
        }
        _ = feed
        let system = try #require(value.object)
        let cpu = try #require(system["cpu"]?.object)
        let shares = try ["user", "system", "idle"].map { try #require(cpu[$0]?.number) }
        #expect(abs(shares.reduce(0, +) - 1) < 0.000_001)
        #expect(system["memory"]?.object?["total"]?.number == Double(ProcessInfo.processInfo.physicalMemory))
        #expect(system["memory"]?.object?["pressure"]?.string != nil)
        let idle = try #require(system["idleSeconds"]?.number)
        #expect(idle >= 0 && idle == idle.rounded(.down))
    }

    @Test func `reads this Mac's counters`() throws {
        let memory = try #require(MemoryUse.read())
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.used > 0 && memory.used <= memory.total)
        #expect(CPUTicks.read() != nil)
    }
}
