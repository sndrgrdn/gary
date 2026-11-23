import AppKit
import GaryCore

nonisolated extension Capability {
    static let mediakeys = Capability(
        name: MediaKey.capability,
        summary: "Take over the volume, brightness, and playback keys.",
        types: """
        declare namespace Gary {
          type MediaKeyName = \(MediaKey.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | "));
          type MediaKeyEvent = { key: MediaKeyName; repeat: boolean; modifiers: ("shift" | "control" | "option" | "command")[] }
          interface Module { onMediaKey?(event: MediaKeyEvent, state: State): HandlerResult }
        }
        """,
        example: """
        let hideTimer = 0;

        export default {
          onMediaKey(event, state) {
            const volume = state.audio?.output?.volume ?? 0;
            host.audio.setVolume(Math.min(1, Math.max(0, volume + (event.key === "volume-up" ? 0.0625 : -0.0625))));
            host.show();
            clearTimeout(hideTimer);
            hideTimer = setTimeout(() => host.hide(), 1500);
          },
          render(state) {
            return { type: "progress", value: state.audio?.output?.volume ?? 0 };
          },
        } satisfies Gary.Overlay;
        """,
        permissions: [.accessibility],
        manifestEntry: #"`"mediakeys": { "overlay": ["volume-up", "volume-down"] }` for `onMediaKey` in that kind, "#
            + "which Gary loads when one of its keys is pressed",
    )
}

final nonisolated class MediaKeyTap: @unchecked Sendable {
    private let lock = NSLock()
    private var claims: [MediaKey: [SlotKey]] = [:]
    private var gate = MediaKey.Gate()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var failing = false
    private let pressed: @MainActor @Sendable (JSON, [SlotKey]) -> Void
    private nonisolated(unsafe) static let runLoop = runLoopThread("gary.mediakeys")

    init(pressed: @escaping @MainActor @Sendable (JSON, [SlotKey]) -> Void) {
        self.pressed = pressed
    }

    func claim(_ claims: [MediaKey: [SlotKey]]) {
        lock.withLock {
            self.claims = claims
            if claims.isEmpty, let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let source {
                    CFRunLoopRemoveSource(Self.runLoop, source, .commonModes)
                }
                CFMachPortInvalidate(tap)
                (self.tap, source) = (nil, nil)
                log("mediakeys: tap removed")
            } else if !claims.isEmpty, tap == nil {
                installTap()
            }
        }
    }

    private func installTap() {
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(NX_SYSDEFINED),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MediaKeyTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque(),
        ) else {
            if !failing {
                log("mediakeys: " + missingGrant(.accessibility, "taking over media keys"))
            }
            failing = true
            return
        }
        failing = false
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(Self.runLoop, source, .commonModes)
        CFRunLoopWakeUp(Self.runLoop)
        (tap, self.source) = (created, source)
        log("mediakeys: tap installed")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            log("mediakeys: tap re-enabled after it was disabled by \(type == .tapDisabledByTimeout ? "a timeout" : "user input")")
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == UInt32(NX_SYSDEFINED), let system = NSEvent(cgEvent: event), system.subtype.rawValue == 8,
              let press = MediaKey.decode(systemDefinedData: system.data1) else { return Unmanaged.passUnretained(event) }
        let (swallowed, targets) = lock.withLock {
            let targets = claims[press.key] ?? []
            return (gate.swallows(press, intercepted: !targets.isEmpty), targets)
        }
        guard swallowed else { return Unmanaged.passUnretained(event) }
        if press.down {
            let modifiers: [(CGEventFlags, String)] = [
                (.maskShift, "shift"),
                (.maskControl, "control"),
                (.maskAlternate, "option"),
                (.maskCommand, "command"),
            ]
            let payload = JSON.object([
                "key": .string(press.key.rawValue),
                "repeat": .bool(press.isRepeat),
                "modifiers": .array(modifiers.filter { event.flags.contains($0.0) }.map { .string($0.1) }),
            ])
            DispatchQueue.main.async { [pressed] in pressed(payload, targets) }
        }
        return nil
    }
}
