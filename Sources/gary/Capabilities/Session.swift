import AppKit
import GaryCore

nonisolated extension Capability {
    static let session = Capability(
        name: "session",
        summary: """
        Whether the screen is locked. The topic changes when the user locks or unlocks the screen, \
        so a plugin can refresh its data after an unlock.
        """,
        types: """
        declare namespace Gary {
          type Session = { locked: boolean }
        }
        """,
        example: """
        let refreshed = "never";

        export default {
          onTopic({ topic, value }) {
            if (topic === "session" && !value.locked) refreshed = new Date().toTimeString().slice(0, 5);
          },
          render() {
            return { type: "text", text: `Refreshed ${refreshed}`, style: "dim" };
          },
        } satisfies Gary.BarWidget;
        """,
        topic: CapabilityTopic(type: "Session") { SessionTopic($0) },
    )
}

private final class SessionTopic: TopicFeed {
    private let publish: @Sendable (JSON, Trace) -> Void
    private var observations: [Observation] = []

    init(_ publish: @escaping @Sendable (JSON, Trace) -> Void) {
        self.publish = publish
        let center = DistributedNotificationCenter.default()
        observations = [
            Observation(center, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.send(locked: true, Trace("lock")) },
            Observation(center, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.send(locked: false, Trace("unlock")) },
        ]
        let session = CGSessionCopyCurrentDictionary() as NSDictionary?
        send(locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false, Trace("session-start"))
    }

    private func send(locked: Bool, _ trace: Trace) {
        publish(.object(["locked": .bool(locked)]), trace)
    }
}

final class PresenceWatch {
    private var locked = (CGSessionCopyCurrentDictionary() as NSDictionary?)?["CGSSessionScreenIsLocked"] as? Bool ?? false
    private var displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    private var systemAsleep = false
    private var observations: [Observation] = []
    private let changed: @MainActor (Bool) -> Void

    var away: Bool {
        locked || displayAsleep || systemAsleep
    }

    init(_ changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observations = [
            Observation(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.update { $0.locked = true } },
            Observation(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.update { $0.locked = false } },
            Observation(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.update { $0.displayAsleep = true } },
            Observation(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.update { $0.displayAsleep = false } },
            Observation(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.update { $0.systemAsleep = true } },
            Observation(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.update { $0.systemAsleep = false } },
        ]
    }

    private func update(_ change: (PresenceWatch) -> Void) {
        let was = away
        change(self)
        if away != was {
            changed(away)
        }
    }
}
