import AppKit
import GaryCore

extension Capability {
    static let clock = Capability(name: "clock", types: """
    declare namespace Gary {
      interface State { clock?: Clock }
      interface Clock { epoch: number }
    }
    """, topic: { ClockTopic($0) })
}

private final class ClockTopic {
    private let publish: (JSON, Trace) -> Void
    private var observations: [Observation] = []

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        send(Trace("clock-start"))
        let next = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.send(Trace("clock")) }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        observations = [
            Observation { timer.invalidate() },
            Observation(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.send(Trace("wake")) },
            Observation(.default, .NSSystemClockDidChange) { [weak self] in self?.send(Trace("clock-change")) },
        ]
    }

    private func send(_ trace: Trace) {
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        publish(.object(["epoch": .number(minute * 1000)]), trace)
    }
}
