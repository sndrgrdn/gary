import Foundation
@testable import gary

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []
    private var waiter: CheckedContinuation<RuntimeEvent, Never>?

    func append(_ event: RuntimeEvent) {
        let waiting = lock.withLock {
            guard let waiter else {
                events.append(event)
                return nil as CheckedContinuation<RuntimeEvent, Never>?
            }
            self.waiter = nil
            return waiter
        }
        waiting?.resume(returning: event)
    }

    func next() async -> RuntimeEvent {
        await withCheckedContinuation { continuation in
            let event = lock.withLock {
                guard !events.isEmpty else {
                    waiter = continuation
                    return nil as RuntimeEvent?
                }
                return events.removeFirst()
            }
            if let event {
                continuation.resume(returning: event)
            }
        }
    }

    func poll() -> RuntimeEvent? {
        lock.withLock { events.isEmpty ? nil : events.removeFirst() }
    }

    var isEmpty: Bool {
        lock.withLock { events.isEmpty }
    }
}

final class ManualTimers: @unchecked Sendable {
    private struct Pending {
        let id: Int
        var due: Double
        let interval: Double?
        let queue: DispatchQueue
        let fire: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var now = 0.0
    private var pending: [Pending] = []
    private var nextID = 0

    @Sendable func start(
        _ seconds: TimeInterval,
        _ repeats: Bool,
        _ queue: DispatchQueue,
        _ fire: @escaping @Sendable () -> Void,
    ) -> @Sendable () -> Void {
        let id = lock.withLock {
            nextID += 1
            pending.append(Pending(id: nextID, due: now + seconds * 1000, interval: repeats ? seconds * 1000 : nil, queue: queue, fire: fire))
            return nextID
        }
        if seconds == 0, !repeats {
            advance(by: 0)
        }
        return { [weak self] in self?.lock.withLock { self?.pending.removeAll { $0.id == id } } }
    }

    func advance(by milliseconds: Double) {
        let target = lock.withLock { now + milliseconds }
        while let next = lock.withLock({ () -> Pending? in
            guard let index = pending.indices.filter({ pending[$0].due <= target }).min(by: { pending[$0].due < pending[$1].due }) else { return nil }
            let timer = pending[index]
            now = max(now, timer.due)
            if let interval = timer.interval {
                pending[index].due += interval
            } else {
                pending.remove(at: index)
            }
            return timer
        }) {
            next.queue.async(execute: next.fire)
        }
        lock.withLock { now = target }
    }
}
