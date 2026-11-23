import AppKit
import Carbon.HIToolbox
import GaryCore
import IOKit.hidsystem
import JavaScriptCore

extension Capability {
    static let hyperkey = Capability(
        name: "hyperkey",
        summary: """
        Make Caps Lock a Hyper key. While Caps Lock is held, every key gets Control, Option, and Command, and Shift too with \
        `shift: true`, so hotkeys written with `hyper`, such as `hyper+m`, fire. Tapping Caps Lock alone does nothing. \
        `host.hyperkey(options)` holds Hyper until `stop()` or the plugin stops. Gary maps Caps Lock to F18 on every keyboard \
        and turns F18 into Hyper in an event tap on its own thread. When a keyboard sends Caps Lock anyway, such as one that \
        connected later or another app that rewrote the mapping, Gary drops that press and maps the keyboards again. \
        When the last hold stops, or Gary quits or crashes, Gary gives Caps Lock back.
        """,
        types: """
        declare namespace Gary {
          interface Host { hyperkey(options?: { shift?: boolean }): HyperKeyApi }
          interface HyperKeyApi { stop(): void }
        }
        """,
        example: """
        host.hyperkey({ shift: false });

        export default {} satisfies Gary.Service;
        """,
        permissions: [.accessibility],
        install: { host, plugin in
            let holds = Holds { HyperKeyTap.shared.release($0) }
            plugin.onStop { holds.stopAll() }
            let hold: @convention(block) (String) -> Int = { text in
                let call = HostCall(api: nil, method: "hyperkey", arguments: [(try? JSON.parse(text)) ?? .null])
                do {
                    let options = call.arguments.first ?? .null
                    guard options == .null || options.object != nil else { throw call.fail("options must be an object such as { shift: true }") }
                    let shift = options["shift"] ?? .null
                    guard shift == .null || shift.bool != nil else { throw call.fail("options.shift must be true or false") }
                    return try holds.add(HyperKeyTap.shared.hold(shift: shift.bool ?? false))
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

private let hyperkeyScript = """
(function (host, hold, stop) {
  host.hyperkey = function (options) {
    var id = hold(JSON.stringify(options === undefined ? null : options));
    return { stop: function () { stop(id); } };
  };
})
"""

final class HyperKeyTap {
    static let shared = HyperKeyTap()
    private static let releaseTag: Int64 = 0x4859_5052
    private let lock = NSLock()
    private var holds: [Int: Bool] = [:]
    private var nextID = 1
    private var gate = HyperKey.Gate()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let mapping = DispatchQueue(label: "gary.hyperkey.mapping", qos: .userInteractive)
    private var replaced: [String: [HyperKey.Mapping]]?
    private lazy var runLoop: CFRunLoop = {
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "gary.hyperkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return loop ?? CFRunLoopGetMain()
    }()

    func hold(shift: Bool) throws -> Int {
        try lock.withLock {
            if tap == nil {
                try start()
            }
            let id = nextID
            nextID += 1
            holds[id] = shift
            gate.shift = shift
            return id
        }
    }

    func release(_ id: Int) {
        lock.withLock {
            guard holds.removeValue(forKey: id) != nil else { return }
            if let newest = holds.max(by: { $0.key < $1.key }) {
                gate.shift = newest.value
            } else {
                stop()
            }
        }
    }

    private func start() throws {
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
            try mapping.sync { try claim() }
        } catch {
            CFMachPortInvalidate(created)
            throw error
        }
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
        (tap, self.source) = (created, source)
        log("hyperkey: Caps Lock is Hyper")
    }

    private func stop() {
        guard let tap else { return }
        letGo()
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        (self.tap, source) = (nil, nil)
        mapping.sync {
            Keyboards.giveBack(replaced ?? [:])
            replaced = nil
            DispatchQueue.main.async { SystemState.update { $0.capsLock = nil } }
        }
        log("hyperkey: Caps Lock is Caps Lock again")
    }

    private func claim() throws {
        let claimed = try Keyboards.claim(replaced ?? [:])
        replaced = claimed
        DispatchQueue.main.async { SystemState.update { $0.capsLock = claimed } }
    }

    private func letGo() {
        guard gate.letGo() else { return }
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(kVK_Control), keyDown: false)
        event?.type = .flagsChanged
        event?.flags = CGEventFlags(rawValue: CGEventSource.flagsState(.hidSystemState).rawValue & ~(HyperKey.Flags.hyper | HyperKey.Flags.capsLock))
        event?.setIntegerValueField(.eventSourceUserData, value: Self.releaseTag)
        event?.post(tap: .cgSessionEventTap)
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
        guard let input, event.getIntegerValueField(.eventSourceUserData) != Self.releaseTag else { return Unmanaged.passUnretained(event) }
        switch lock.withLock({ gate.decide(input, flags: event.flags.rawValue) }) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .drop:
            return nil
        case let .flags(flags):
            event.flags = CGEventFlags(rawValue: flags)
            return Unmanaged.passUnretained(event)
        case let .modifier(flags):
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Control))
            event.flags = CGEventFlags(rawValue: flags)
            return Unmanaged.passUnretained(event)
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

enum Keyboards {
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private static let property = "UserKeyMapping" as CFString
    private static let source = "HIDKeyboardModifierMappingSrc"
    private static let destination = "HIDKeyboardModifierMappingDst"

    static func claim(_ replaced: [String: [HyperKey.Mapping]]) throws -> [String: [HyperKey.Mapping]] {
        var replaced = replaced
        for keyboard in all() {
            guard let claimed = try HyperKey.claim(mappings(of: keyboard)) else { continue }
            try write(claimed.mappings, to: keyboard)
            replaced[id(of: keyboard)] = claimed.replaced
        }
        try switchCapsLockOff()
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
        guard let value = IOHIDServiceClientCopyProperty(keyboard, property) else { return [] }
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
        guard IOHIDServiceClientSetProperty(keyboard, property, value as CFArray) else {
            throw HostFailure("the key mapping of \(name(of: keyboard)) could not be written")
        }
    }

    private static func switchCapsLockOff() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { throw HostFailure("IOHIDSystem is missing, so Caps Lock could not be switched off") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            throw HostFailure("IOHIDSystem could not be opened, so Caps Lock could not be switched off")
        }
        defer { IOServiceClose(connection) }
        guard IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS else {
            throw HostFailure("Caps Lock could not be switched off")
        }
    }
}
