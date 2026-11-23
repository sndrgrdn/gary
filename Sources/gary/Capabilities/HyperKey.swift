import AppKit
import Carbon.HIToolbox
import GaryCore
import IOKit.hidsystem
@preconcurrency import JavaScriptCore

nonisolated extension Capability {
    static let hyperkey = Capability(
        name: "hyperkey",
        summary: """
        Make a key a Hyper key. While the key is held, every other key gets Control, Option, and Command, and Shift too with \
        `shift: true`, so hotkeys written with `hyper`, such as `hyper+m`, fire. `key` names the key: `capsLock`, the default; \
        a modifier side, \(HyperKey.Trigger.sides.map { "`\($0.name)`" }.joined(separator: ", ")); or a hotkey key name, such as \
        `f19`, `escape`, or `a`. Tapping the key alone does nothing unless `tap` names a key to send instead, and \
        `tap: "capsLock"` toggles Caps Lock. A tap is a press and release within \(HyperKey.tappingTerm / 1_000_000) ms with no other key pressed. \
        `host.hyperkey(options)` holds Hyper until `stop()` or the plugin stops, and the newest hold's options win. Gary turns \
        the key into Hyper in an event tap on its own thread, and for Caps Lock first maps Caps Lock to F18 on every keyboard. \
        When a keyboard sends Caps Lock anyway, such as one that connected later or another app that rewrote the mapping, Gary \
        drops that press and maps the keyboards again. When the last hold stops, or Gary quits or crashes, Gary gives Caps \
        Lock back.
        """,
        types: """
        declare namespace Gary {
          interface Host { hyperkey(options?: \(HyperKey.optionsType)): HyperKeyApi }
          interface HyperKeyApi { stop(): void }
        }
        """,
        example: """
        host.hyperkey({ key: "capsLock", shift: false, tap: "escape" });

        export default {} satisfies Gary.Service;
        """,
        permissions: [.accessibility],
        install: { host, plugin in
            let holds = Holds { HyperKeyTap.shared.release($0) }
            plugin.onStop { holds.stopAll() }
            let hold: @convention(block) (String) -> Int = { text in
                let call = HostCall(api: nil, method: "hyperkey", arguments: [(try? JSON.parse(text)) ?? .null])
                do {
                    return try holds.add(HyperKeyTap.shared.hold(options(call)))
                } catch {
                    let context = JSContext.current()
                    context?.exception = context?.newError("\(error)")
                    return 0
                }
            }
            let stop: @convention(block) (Int) -> Void = { holds.stop($0) }
            host.context.evaluateScript(hyperkeyScript).call(withArguments: [host, hold, stop])
        },
    )
}

private nonisolated func options(_ call: HostCall) throws -> HyperKey.Options {
    let options = call.arguments.first ?? .null
    guard options == .null || options.object != nil else { throw call.fail("options must be an object such as { key: \"capsLock\", shift: true }") }
    let key = options["key"] ?? .null
    let shift = options["shift"] ?? .null
    let tap = options["tap"] ?? .null
    let keys = "a hotkey key name, such as a, 1, ;, return, space, tab, escape, delete, left, or f1 to f20"
    guard let trigger = key == .null ? HyperKey.Trigger.capsLock : key.string.flatMap(HyperKey.Trigger.init(named:)) else {
        throw call.fail("options.key must name a key: capsLock, \(HyperKey.Trigger.sides.map(\.name).joined(separator: ", ")), or \(keys)")
    }
    guard shift == .null || shift.bool != nil else { throw call.fail("options.shift must be true or false") }
    let tapped = tap.string.flatMap(HyperKey.Tap.init(named:))
    guard tap == .null || tapped != nil else { throw call.fail("options.tap must name a key: capsLock, which toggles Caps Lock, or \(keys)") }
    return HyperKey.Options(trigger: trigger, shift: shift.bool ?? false, tap: tapped)
}

private nonisolated let hyperkeyScript = """
(function (host, hold, stop) {
  host.hyperkey = function (options) {
    var id = hold(JSON.stringify(options === undefined ? null : options));
    return { stop: function () { stop(id); } };
  };
})
"""

final nonisolated class HyperKeyTap: @unchecked Sendable {
    static let shared = HyperKeyTap()
    private static let ownTag: Int64 = 0x4859_5052
    private let lock = NSLock()
    private var holds: [Int: HyperKey.Options] = [:]
    private var nextID = 1
    private var gate = HyperKey.Gate()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let mapping = DispatchQueue(label: "gary.hyperkey.mapping", qos: .userInteractive)
    private var replaced: [String: [HyperKey.Mapping]]?
    private nonisolated(unsafe) static let runLoop = runLoopThread("gary.hyperkey")

    func hold(_ options: HyperKey.Options) throws -> Int {
        try lock.withLock {
            if tap == nil {
                try start(options)
            } else {
                try use(options)
            }
            let id = nextID
            nextID += 1
            holds[id] = options
            return id
        }
    }

    func release(_ id: Int) {
        lock.withLock {
            guard holds.removeValue(forKey: id) != nil else { return }
            guard let newest = holds.max(by: { $0.key < $1.key }) else { return stop() }
            do {
                try use(newest.value)
            } catch {
                log("hyperkey: \(error)")
            }
        }
    }

    private func use(_ options: HyperKey.Options) throws {
        if options.trigger != gate.options.trigger {
            letGo()
            try mapping.sync { options.trigger.kind == .capsLock ? try claim() : giveBack() }
            log("hyperkey: \(options.trigger.name) is Hyper")
        }
        gate.options = options
    }

    private func start(_ options: HyperKey.Options) throws {
        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue },
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HyperKeyTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque(),
        ) else { throw HostFailure(missingGrant(.accessibility, "holding Hyper")) }
        do {
            if options.trigger.kind == .capsLock {
                try mapping.sync { try claim() }
            }
        } catch {
            CFMachPortInvalidate(created)
            throw error
        }
        gate.options = options
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(Self.runLoop, source, .commonModes)
        CFRunLoopWakeUp(Self.runLoop)
        (tap, self.source) = (created, source)
        log("hyperkey: \(options.trigger.name) is Hyper")
    }

    private func stop() {
        guard let tap else { return }
        letGo()
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(Self.runLoop, source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        (self.tap, source) = (nil, nil)
        mapping.sync { giveBack() }
        log("hyperkey: \(gate.options.trigger.name) is no longer Hyper")
    }

    private func claim() throws {
        let claimed = try Keyboards.claim(replaced ?? [:])
        replaced = claimed
        DispatchQueue.main.async { SystemState.update { $0.capsLock = claimed } }
    }

    private func giveBack() {
        guard let replaced else { return }
        Keyboards.giveBack(replaced)
        self.replaced = nil
        DispatchQueue.main.async { SystemState.update { $0.capsLock = nil } }
    }

    private func letGo() {
        guard gate.letGo() else { return }
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(kVK_Control), keyDown: false)
        event?.type = .flagsChanged
        let held = CGEventSource.flagsState(.hidSystemState).rawValue
        event?.flags = CGEventFlags(rawValue: gate.options.trigger.stripping(held) & ~HyperKey.Flags.hyper)
        event?.setIntegerValueField(.eventSourceUserData, value: Self.ownTag)
        event?.post(tap: .cgSessionEventTap)
    }

    private func send(_ tap: HyperKey.Tap, flags: UInt64) {
        switch tap {
        case .capsLock:
            mapping.async {
                do {
                    try Keyboards.toggleCapsLock()
                } catch {
                    log("hyperkey: \(error)")
                }
            }
        case let .key(code):
            CFRunLoopPerformBlock(Self.runLoop, CFRunLoopMode.commonModes.rawValue) {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: down)
                    event?.flags = CGEventFlags(rawValue: flags)
                    event?.setIntegerValueField(.eventSourceUserData, value: Self.ownTag)
                    event?.post(tap: .cgSessionEventTap)
                }
            }
            CFRunLoopWakeUp(Self.runLoop)
        }
    }

    private func modifier(_ event: CGEvent, _ flags: UInt64) -> Unmanaged<CGEvent> {
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Control))
        event.flags = CGEventFlags(rawValue: flags)
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock {
                guard let tap else { return }
                letGo()
                CGEvent.tapEnable(tap: tap, enable: true)
                log("hyperkey: tap re-enabled after it was disabled by \(type == .tapDisabledByTimeout ? "a timeout" : "user input")")
            }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let input: HyperKey.Event? = switch type {
        case .keyDown: .keyDown(code, autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: .keyUp(code)
        case .flagsChanged: .flagsChanged(code)
        default: nil
        }
        guard let input, event.getIntegerValueField(.eventSourceUserData) != Self.ownTag else { return Unmanaged.passUnretained(event) }
        let now = DispatchTime.now().uptimeNanoseconds
        switch lock.withLock({ gate.decide(input, flags: event.flags.rawValue, at: now) }) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .drop:
            return nil
        case let .flags(flags):
            event.flags = CGEventFlags(rawValue: flags)
            return Unmanaged.passUnretained(event)
        case let .modifier(flags):
            return modifier(event, flags)
        case let .tap(flags, tap):
            send(tap, flags: flags)
            return modifier(event, flags)
        case .remap:
            mapping.async { [self] in
                guard replaced != nil else { return }
                log("hyperkey: Caps Lock arrived unmapped, so a keyboard lost the F18 mapping; mapping every keyboard again")
                do {
                    try claim()
                } catch {
                    log("hyperkey: \(error)")
                }
            }
            return nil
        }
    }
}

nonisolated enum Keyboards {
    private nonisolated(unsafe) static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private static let property = "UserKeyMapping"
    private static let source = "HIDKeyboardModifierMappingSrc"
    private static let destination = "HIDKeyboardModifierMappingDst"

    static func claim(_ replaced: [String: [HyperKey.Mapping]]) throws -> [String: [HyperKey.Mapping]] {
        var replaced = replaced
        for keyboard in all() {
            guard let claimed = try HyperKey.claim(mappings(of: keyboard)) else { continue }
            try write(claimed.mappings, to: keyboard)
            replaced[id(of: keyboard)] = claimed.replaced
        }
        try setCapsLock { _ in false }
        return replaced
    }

    static func giveBack(_ replaced: [String: [HyperKey.Mapping]]) {
        for keyboard in all() {
            do {
                guard let restored = try HyperKey.giveBack(mappings(of: keyboard), restoring: replaced[id(of: keyboard)] ?? []) else { continue }
                try write(restored, to: keyboard)
            } catch {
                log("hyperkey: \(error)")
            }
        }
    }

    private static func all() -> [IOHIDServiceClient] {
        ((IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []).filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
    }

    private static func id(of keyboard: IOHIDServiceClient) -> String {
        "\(IOHIDServiceClientGetRegistryID(keyboard))"
    }

    private static func name(of keyboard: IOHIDServiceClient) -> String {
        "\(IOHIDServiceClientCopyProperty(keyboard, kIOHIDProductKey as CFString) as? String ?? "keyboard") \(id(of: keyboard))"
    }

    private static func mappings(of keyboard: IOHIDServiceClient) throws -> [HyperKey.Mapping] {
        guard let value = IOHIDServiceClientCopyProperty(keyboard, property as CFString) else { return [] }
        guard let entries = value as? [[String: NSNumber]]
        else { throw HostFailure("the UserKeyMapping of \(name(of: keyboard)) is not a list of mappings") }
        return try entries.map { entry in
            guard let from = entry[source], let to = entry[destination] else {
                throw HostFailure("the UserKeyMapping of \(name(of: keyboard)) has an entry without \(source) and \(destination)")
            }
            return HyperKey.Mapping(source: from.uint64Value, destination: to.uint64Value)
        }
    }

    private static func write(_ mappings: [HyperKey.Mapping], to keyboard: IOHIDServiceClient) throws {
        let value = mappings.map { [source: NSNumber(value: $0.source), destination: NSNumber(value: $0.destination)] }
        guard IOHIDServiceClientSetProperty(keyboard, property as CFString, value as CFArray) else {
            throw HostFailure("the key mapping of \(name(of: keyboard)) could not be written")
        }
    }

    static func toggleCapsLock() throws {
        try setCapsLock { !$0 }
    }

    private static func setCapsLock(_ change: (Bool) -> Bool) throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { throw HostFailure("IOHIDSystem is missing, so Caps Lock could not be set") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            throw HostFailure("IOHIDSystem could not be opened, so Caps Lock could not be set")
        }
        defer { IOServiceClose(connection) }
        var locked = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS,
              IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), change(locked)) == KERN_SUCCESS
        else { throw HostFailure("Caps Lock could not be set") }
    }
}
