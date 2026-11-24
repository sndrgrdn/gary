import Foundation
import GaryCore
import Synchronization

nonisolated enum TraceLog {
    static let idle: TimeInterval = 3
    static let kept = 100_000
    static let batch = 5000

    private struct Store {
        var events: [(time: Double, line: JSON)] = []
        var first = 0
        var nextCause: UInt64 = 1
        var values = false
        var deadline = 0.0
        var framesChecked = 0.0
    }

    private static let recording = Atomic<Bool>(false)
    private static let store = Mutex(Store())
    @MainActor static var applying: UInt64 = 0

    static var isOn: Bool {
        recording.load(ordering: .relaxed)
    }

    static var keepsValues: Bool {
        isOn && store.withLock(\.values)
    }

    static func uptime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    static func cause(_ name: String) -> UInt64 {
        guard isOn else { return 0 }
        let id = store.withLock { store in
            defer { store.nextCause += 1 }
            return store.nextCause
        }
        append("cause", id, ["cause": .string(name)])
        return id
    }

    static func note(_ event: String, _ trace: UInt64, _ fields: @autoclosure () -> [String: JSON]) {
        guard isOn else { return }
        append(event, trace, fields())
    }

    static func slot(_ slot: SlotKey) -> JSON {
        .string(slot.description)
    }

    static func milliseconds(since start: Double) -> JSON {
        .number(((uptime() - start) * 1e6).rounded() / 1000)
    }

    private static func append(_ event: String, _ trace: UInt64, _ fields: [String: JSON], at time: Double = uptime()) {
        var fields = fields
        fields["t"] = .number(time)
        fields["ev"] = .string(event)
        if trace != 0 {
            fields["trace"] = .number(Double(trace))
        }
        let line = JSON.object(fields)
        store.withLock { store in
            guard recording.load(ordering: .relaxed) else { return }
            guard time <= store.deadline else {
                recording.store(false, ordering: .relaxed)
                store = Store(nextCause: store.nextCause)
                return
            }
            store.events.append((time, line))
            if store.events.count > kept {
                store.events.removeFirst(kept / 2)
                store.first += kept / 2
            }
        }
    }

    static func poll(from cursor: Int?, values: Bool, hitches: (Double) -> [(time: Double, fields: [String: JSON])]) -> JSON {
        let time = uptime()
        let checked = store.withLock { store in
            if !recording.load(ordering: .relaxed) {
                store = Store(nextCause: store.nextCause, framesChecked: time)
                recording.store(true, ordering: .relaxed)
            }
            store.deadline = time + idle
            store.values = store.values || values
            defer { store.framesChecked = time }
            return store.framesChecked
        }
        for hitch in hitches(checked) {
            append("hitch", 0, hitch.fields, at: hitch.time)
        }
        return store.withLock { store in
            let end = store.first + store.events.count
            let start = max(cursor ?? end, store.first)
            let next = min(end, start + batch)
            let events = store.events[(start - store.first)..<(next - store.first)].sorted { $0.time < $1.time }.map(\.line)
            return .object([
                "next": .number(Double(next)),
                "dropped": .number(Double(start - (cursor ?? start))),
                "events": .array(events),
            ])
        }
    }
}

nonisolated struct HostCallNote {
    let slot: SlotKey
    let name: String
    let from: UInt64
    let started: Double

    init(_ runtime: PluginRuntime, _ name: String) {
        slot = runtime.slot
        self.name = name
        guard TraceLog.isOn else {
            from = 0
            started = 0
            return
        }
        from = runtime.assumeIsolated { $0.entryTrace }
        started = TraceLog.uptime()
        TraceLog.note("host", from, ["plugin": TraceLog.slot(slot), "call": .string(name)])
    }

    func finished(_ trace: Trace, ok: Bool) {
        TraceLog.note("hostDone", trace.id, [
            "plugin": TraceLog.slot(slot),
            "call": .string(name),
            "from": .number(Double(from)),
            "ok": .bool(ok),
            "ms": started > 0 ? TraceLog.milliseconds(since: started) : .null,
        ])
    }
}

nonisolated extension PluginRuntime {
    var slot: SlotKey {
        SlotKey(id: id, kind: kind)
    }
}
