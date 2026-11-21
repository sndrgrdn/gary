import AppKit
import GaryCore

final class ClockProvider {
    private let hub: StateHub
    private var timer: Timer?

    init(hub: StateHub) { self.hub = hub }

    func start() {
        publish(Trace("clock-start"))
        let next = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.publish(Trace("clock")) }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publish(Trace("wake"))
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.publish(Trace("clock-change")) }
    }

    private func publish(_ trace: Trace) {
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        hub.publish(ClockSnapshot(epochMilliseconds: minute * 1000), trace)
    }
}
