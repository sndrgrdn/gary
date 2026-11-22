import AppKit
import GaryCore

extension Capability {
    static let mediakeys = Capability(name: "mediakeys", summary: "Take over the volume, mute, and brightness keys.", types: """
    declare namespace Gary {
      type MediaKeyName = "volume-up" | "volume-down" | "mute" | "brightness-up" | "brightness-down";
      interface MediaKeyEvent { key: MediaKeyName; repeat: boolean; modifiers: ("shift" | "control" | "option" | "command")[] }
      interface Module { onMediaKey?(event: MediaKeyEvent, state: State): void }
      interface Host { mediakeys: { intercept(keys: MediaKeyName[]): boolean } }
    }
    """, example: """
    host.mediakeys.intercept(["volume-up", "volume-down"]);
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
    """, permissions: [.accessibility], install: { host, plugin in
        plugin.installAPI(host, "mediakeys", MediaKeysRequest.methods) { [weak plugin] call in
            switch try MediaKeysRequest.parse(call) {
            case let .intercept(keys):
                guard let plugin else { return .now(.bool(false)) }
                return try .now(.bool(KeyTap.shared.intercept(keys, for: plugin)))
            }
        }
    })
}

private struct KeyListener {
    let keys: Set<MediaKey>
    weak var plugin: PluginRuntime?
}

private final class KeyTap {
    static let shared = KeyTap()
    private let lock = NSLock()
    private var listeners: [ObjectIdentifier: KeyListener] = [:]
    private var gate = MediaKey.Gate()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private lazy var runLoop: CFRunLoop = {
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "gary.mediakeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return loop ?? CFRunLoopGetMain()
    }()

    func intercept(_ keys: Set<MediaKey>, for plugin: PluginRuntime) throws -> Bool {
        let id = ObjectIdentifier(plugin)
        let isNew = lock.withLock {
            let isNew = listeners[id] == nil
            listeners[id] = keys.isEmpty ? nil : KeyListener(keys: keys, plugin: plugin)
            return isNew && !keys.isEmpty
        }
        if isNew {
            plugin.onStop { [weak self] in self?.remove(id) }
        }
        let intercepting = update()
        guard intercepting || keys.isEmpty else {
            lock.withLock { listeners[id] = nil }
            throw HostFailure(missingGrant(.accessibility, "mediakeys"))
        }
        return intercepting
    }

    private func remove(_ id: ObjectIdentifier) {
        lock.withLock { listeners[id] = nil }
        _ = update()
    }

    private func update() -> Bool {
        lock.withLock {
            if listeners.isEmpty, let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let source {
                    CFRunLoopRemoveSource(runLoop, source, .commonModes)
                }
                CFMachPortInvalidate(tap)
                (self.tap, source) = (nil, nil)
                log("mediakeys: tap removed")
            } else if !listeners.isEmpty, tap == nil {
                guard let created = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: CGEventMask(1) << CGEventMask(NX_SYSDEFINED),
                    callback: { _, type, event, _ in KeyTap.shared.handle(type, event) },
                    userInfo: nil,
                ) else {
                    log("mediakeys: " + missingGrant(.accessibility, "intercepting keys"))
                    return false
                }
                let source = CFMachPortCreateRunLoopSource(nil, created, 0)
                CFRunLoopAddSource(runLoop, source, .commonModes)
                CFRunLoopWakeUp(runLoop)
                (tap, self.source) = (created, source)
                log("mediakeys: tap installed")
            }
            return tap != nil
        }
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
            let targets = listeners.values.filter { $0.keys.contains(press.key) }.compactMap(\.plugin)
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
            for plugin in targets {
                plugin.mediaKey(payload)
            }
        }
        return nil
    }
}
