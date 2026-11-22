import AppKit
import ApplicationServices
import Synchronization

struct SoundOutput {
    let name: String
    let selected: Bool
}

enum ControlCenter {
    static let queue = DispatchQueue(label: "gary.controlcenter", qos: .userInitiated)
    static let isOpen = Atomic(false)

    private static let menuExtra = "com.apple.menuextra.controlcenter"
    private static let soundModule = "module-Sound"
    private static let outputPrefix = "sound-device-"
    private static let escape: CGKeyCode = 53

    static func soundOutputs() throws -> [SoundOutput] {
        let start = now()
        let outputs = try withSoundOutputs { $0.map(\.output) }
        log("controlcenter: listed \(outputs.count) sound outputs in \(Int((now() - start) * 1000)) ms")
        return outputs
    }

    static func selectSoundOutput(_ name: String) throws {
        try withSoundOutputs { rows in
            guard let row = rows.first(where: { $0.output.name == name }) else { throw HostFailure("Control Center has no sound output \(name)") }
            if !row.output.selected {
                AXUIElementPerformAction(row.element, kAXPressAction as CFString)
            }
        }
    }

    private static func withSoundOutputs<T>(_ body: ([(output: SoundOutput, element: AXUIElement)]) throws -> T) throws -> T {
        guard AXIsProcessTrusted() else { throw HostFailure(missingGrant(.accessibility, "AirPlay")) }
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { throw HostFailure("Control Center is not running") }
        let app = AXUIElementCreateApplication(center.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let extras = attribute(AXUIElementCreateApplication(agent.processIdentifier), "AXExtrasMenuBar", as: AXUIElement.self),
              let item = all(in: extras, where: { identifier($0) == menuExtra }).first
        else { throw HostFailure("Control Center is not in the menu bar") }
        isOpen.store(true, ordering: .sequentiallyConsistent)
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        defer { close(app, center.processIdentifier) }
        guard let sound = wait(for: { windows(app).flatMap { all(in: $0, where: { identifier($0) == soundModule }) }.first }) else {
            throw HostFailure("Control Center has no Sound control; add it with Edit Controls in Control Center")
        }
        AXUIElementPerformAction(sound, kAXPressAction as CFString)
        let rows = wait {
            let rows = outputs(app)
            return rows.isEmpty ? nil : rows
        }
        guard let rows else { throw HostFailure("Control Center did not list its sound outputs") }
        return try body(rows)
    }

    private static func close(_ app: AXUIElement, _ pid: pid_t) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: down)?.postToPid(pid)
        }
        queue.async {
            _ = wait(for: { windows(app).isEmpty ? true : nil })
            isOpen.store(false, ordering: .sequentiallyConsistent)
        }
    }

    private static func outputs(_ app: AXUIElement) -> [(output: SoundOutput, element: AXUIElement)] {
        windows(app).flatMap { all(in: $0, where: { identifier($0).hasPrefix(outputPrefix) }) }.map { element in
            let output = SoundOutput(
                name: String(identifier(element).dropFirst(outputPrefix.count)),
                selected: attribute(element, kAXValueAttribute, as: Int.self) == 1,
            )
            return (output, element)
        }
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        children(app, kAXWindowsAttribute)
    }

    private static func identifier(_ element: AXUIElement) -> String {
        attribute(element, kAXIdentifierAttribute, as: String.self) ?? ""
    }

    private static func all(in element: AXUIElement, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        (match(element) ? [element] : []) + children(element).flatMap { all(in: $0, where: match) }
    }

    private static func wait<Value>(for value: () -> Value?) -> Value? {
        for _ in 0..<200 {
            if let value = value() {
                return value
            }
            usleep(10000)
        }
        return nil
    }
}
