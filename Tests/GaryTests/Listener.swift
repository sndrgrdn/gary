import Foundation
@testable import gary
import GaryCore

final class Listener: Subscriber, @unchecked Sendable {
    let slot: SlotKey
    private let lock = NSLock()
    private var received: [JSON] = []

    init(_ slot: SlotKey = SlotKey(id: .onboarding, kind: .barWidget)) {
        self.slot = slot
    }

    func receive(_: Topic, _ value: JSON, _: Trace) {
        lock.withLock { received.append(value) }
    }

    var values: [JSON] {
        lock.withLock { received }
    }
}
