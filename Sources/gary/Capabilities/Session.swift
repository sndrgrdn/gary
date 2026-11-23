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
