import Foundation

nonisolated enum EngineCause: Int, CaseIterable {
    case load, render, timer, topic, action, call, host
}

nonisolated struct PluginStats: Equatable {
    var cpu: Duration = .zero
    var recentCPU: Duration = .zero
    var entries: [EngineCause: Int] = [:]
    var longestEntry: Duration = .zero
    var overTimeLimit = 0
    var renders = 0
    var lastRenderNodes = 0
    var timerFiresPerMinute = 0
    var timeouts = 0
    var intervals = 0
    var pendingHostCalls: [String: Int] = [:]
}

nonisolated struct RecentTotal {
    static let seconds = 60
    private var stamps = [Int](repeating: -seconds, count: seconds)
    private var totals = [Int64](repeating: 0, count: seconds)

    mutating func add(_ amount: Int64, at second: Int) {
        let slot = second % Self.seconds
        if stamps[slot] != second {
            stamps[slot] = second
            totals[slot] = 0
        }
        totals[slot] += amount
    }

    func sum(at second: Int) -> Int64 {
        zip(stamps, totals).reduce(0) { sum, slot in second - slot.0 < Self.seconds ? sum + slot.1 : sum }
    }
}

final nonisolated class PluginMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Int
    private var stats = PluginStats()
    private var entries = [Int](repeating: 0, count: EngineCause.allCases.count)
    private var recentCPU = RecentTotal()
    private var recentFires = RecentTotal()

    init(clock: @escaping @Sendable () -> Int = { Int(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000_000) }) {
        self.clock = clock
    }

    func entered(_ cause: EngineCause, spent: Duration, stopped: Bool) {
        let second = clock()
        lock.withLock {
            entries[cause.rawValue] += 1
            stats.cpu += spent
            recentCPU.add(Int64(spent / .nanoseconds(1)), at: second)
            stats.longestEntry = max(stats.longestEntry, spent)
            stats.overTimeLimit += stopped ? 1 : 0
            if cause == .timer {
                recentFires.add(1, at: second)
            }
        }
    }

    func rendered(nodes: Int) {
        lock.withLock {
            stats.renders += 1
            stats.lastRenderNodes = nodes
        }
    }

    func timer(repeats: Bool, _ cancel: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.withLock { repeats ? (stats.intervals += 1) : (stats.timeouts += 1) }
        return { [self] in
            cancel()
            lock.withLock { repeats ? (stats.intervals -= 1) : (stats.timeouts -= 1) }
        }
    }

    func hostCallStarted(_ name: String) {
        lock.withLock { stats.pendingHostCalls[name, default: 0] += 1 }
    }

    func hostCallFinished(_ name: String) {
        lock.withLock { stats.pendingHostCalls[name, default: 0] -= 1 }
    }

    var snapshot: PluginStats {
        let second = clock()
        return lock.withLock {
            var snapshot = stats
            snapshot.entries = Dictionary(uniqueKeysWithValues: EngineCause.allCases.map { ($0, entries[$0.rawValue]) })
            snapshot.recentCPU = .nanoseconds(recentCPU.sum(at: second))
            snapshot.timerFiresPerMinute = Int(recentFires.sum(at: second))
            snapshot.pendingHostCalls = snapshot.pendingHostCalls.filter { $0.value > 0 }
            return snapshot
        }
    }
}
