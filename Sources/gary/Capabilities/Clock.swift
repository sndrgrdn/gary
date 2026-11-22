import AppKit
import GaryCore

extension Capability {
    static let clock = Capability(name: "clock", summary: """
    The current minute, updated each minute and after sleep, and whether macOS shows 12-hour time.
    """, types: """
    declare namespace Gary {
      type Clock = { epoch: number; hour12: boolean }
    }
    """, example: """
    export default {
      render(state) {
        const now = new Date(state.clock?.epoch ?? Date.now());
        const text = now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit", hour12: state.clock?.hour12 });
        return { type: "text", text, style: "bright" };
      },
    } satisfies Gary.BarWidget;
    """, topic: CapabilityTopic(type: "Clock") { ClockTopic($0) })
}

extension Locale {
    var hour12: Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: self) ?? "HH"
        return !pattern.contains { "Hk".contains($0) }
    }
}

private final class ClockTopic: TopicFeed {
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
            Observation(.default, NSLocale.currentLocaleDidChangeNotification) { [weak self] in self?.send(Trace("locale-change")) },
        ]
    }

    private func send(_ trace: Trace) {
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        publish(.object(["epoch": .number(minute * 1000), "hour12": .bool(Locale.autoupdatingCurrent.hour12)]), trace)
    }
}
