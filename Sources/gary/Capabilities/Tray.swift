import AppKit
import ApplicationServices
import GaryCore
import GaryPrivate

private let trayQueue = DispatchQueue(label: "gary.tray", qos: .userInitiated)

extension Capability {
    static let tray = Capability(name: "tray", summary: """
    The status items in the menu bar, with their icons, refreshed every 2 seconds while a plugin subscribes. \
    Without Screen Recording the items have no icons, and reason says why. Press one with the left or right button and modifier keys.
    """, types: """
    declare namespace Gary {
      type Tray = { available: boolean; reason?: string; items: TrayItem[] }
      type TrayItem = {
        id: string;
        app: string;
        name: string;
        pid: number;
        title: string | null;
        description: string | null;
        x: number;
        y: number;
        width: number;
        height: number;
        icon: string | null;
      }
      interface TrayPress { button?: "left" | "right"; modifiers?: ("cmd" | "ctrl" | "alt" | "shift")[] }
      interface Host { tray: TrayApi }
      interface TrayApi {
        press(id: string, options?: TrayPress): Promise<TrayItem & { opened: boolean }>;
      }
    }
    """, example: """
    export default {
      render(state) {
        return {
          type: "row",
          children: (state.tray?.items ?? []).map((item): Gary.Node => item.icon
            ? { type: "image", key: item.id, path: item.icon, action: item.id, rightAction: `right ${item.id}` }
            : { type: "text", key: item.id, text: item.name, action: item.id, rightAction: `right ${item.id}` }),
        };
      },
      onAction(action) {
        const [button, id] = action.startsWith("right ") ? (["right", action.slice(6)] as const) : (["left", action] as const);
        host.tray.press(id, { button }).then((item) => host.log(`${item.name} opened a menu: ${item.opened}`));
      },
    } satisfies Gary.BarWidget;
    """, permissions: [.accessibility, .screenRecording], install: { host, plugin in
        plugin.installAPI(host, "tray", TrayRequest.methods) { call in
            let request = try TrayRequest.parse(call)
            return .later(trayQueue) {
                guard AXIsProcessTrusted() else { throw HostFailure(missingGrant(.accessibility, "the tray")) }
                switch request {
                case let .press(id, how):
                    guard let item = try scan().first(where: { $0.id == id }) else { throw HostFailure("no tray item \(id)") }
                    guard case var .object(fields) = item.json(icon: nil) else { return .null }
                    fields["opened"] = try .bool(click(item.element.frame, how))
                    return .object(fields)
                }
            }
        }
    }, topic: CapabilityTopic(type: "Tray") { TrayTopic($0) })
}

private final class TrayTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private let timer = DispatchSource.makeTimerSource(queue: trayQueue)
    private var icons: Set<String> = []

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    private func refresh() {
        let items: [TrayItem]
        do {
            guard AXIsProcessTrusted() else { throw HostFailure(missingGrant(.accessibility, "the tray")) }
            items = try scan()
        } catch {
            publish(.object(["available": .bool(false), "reason": .string("\(error)"), "items": .array([])]), Trace("tray"))
            return
        }
        let captured = capture(items)
        let current = Set(captured.paths.values)
        let folder = pngFolder("tray")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appending(path: name).path
            if !current.contains(path), !icons.contains(path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        icons = current
        var tray: [String: JSON] = ["available": .bool(true), "items": .array(items.map { $0.json(icon: captured.paths[$0.id]) })]
        tray["reason"] = captured.error.map(JSON.string)
        publish(.object(tray), Trace("tray"))
    }
}

private func attribute<Value>(_ element: AXUIElement, _ name: String, as _: Value.Type) -> Value? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? Value
}

private func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    attribute(element, name, as: [AXUIElement].self) ?? []
}

private func frame(_ element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero
    var size = CGSize.zero
    if let position = attribute(element, kAXPositionAttribute, as: AXValue.self) {
        AXValueGetValue(position, .cgPoint, &origin)
    }
    if let extent = attribute(element, kAXSizeAttribute, as: AXValue.self) {
        AXValueGetValue(extent, .cgSize, &size)
    }
    return CGRect(origin: origin, size: size)
}

private func scan() throws -> [TrayItem] {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
        throw HostFailure("MenuBarAgent is not running")
    }
    let application = AXUIElementCreateApplication(agent.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 1)
    var elements: [TrayElement] = []
    for window in children(application, kAXWindowsAttribute) {
        for group in children(window) {
            guard let child = children(group).first else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            let owner = NSRunningApplication(processIdentifier: pid)
            let button = attribute(child, kAXRoleAttribute, as: String.self) == kAXButtonRole
            elements.append(TrayElement(
                frame: frame(group), app: owner?.bundleIdentifier ?? "pid:\(pid)", name: owner?.localizedName ?? "", pid: pid,
                title: button ? attribute(child, kAXTitleAttribute, as: String.self) : nil,
                detail: button ? attribute(child, kAXDescriptionAttribute, as: String.self) : nil,
            ))
        }
    }
    return TrayItem.merge(elements)
}

private struct ModifierKey {
    let modifier: KeyCombo.Modifiers
    let code: CGKeyCode
    let flag: CGEventFlags
}

private let modifierKeys = [
    ModifierKey(modifier: .command, code: 55, flag: .maskCommand), ModifierKey(modifier: .shift, code: 56, flag: .maskShift),
    ModifierKey(modifier: .option, code: 58, flag: .maskAlternate), ModifierKey(modifier: .control, code: 59, flag: .maskControl),
]

private func click(_ frame: CGRect, _ how: TrayClick) throws -> Bool {
    guard CGPreflightPostEventAccess() else { throw HostFailure(missingGrant(.accessibility, "tray.press")) }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let before = Set(popups())
    let restore = DispatchQueue.main.sync { passClicks(at: point) }
    defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: restore) }
    let pointer = CGEvent(source: nil)?.location
    if UserDefaults.standard.bool(forKey: "_HIHideMenuBar") {
        let edge = CGPoint(x: point.x, y: 0)
        CGWarpMouseCursorPosition(edge)
        post(.mouseMoved, at: edge)
        usleep(700_000)
    }
    let held = modifierKeys.filter { how.modifiers.contains($0.modifier) }
    var flags: CGEventFlags = []
    for key in held {
        flags.insert(key.flag)
        post(key: key.code, down: true, flags: flags)
    }
    let right = how.button == .right
    post(right ? .rightMouseDown : .leftMouseDown, at: point, button: right ? .right : .left, flags: flags)
    post(right ? .rightMouseUp : .leftMouseUp, at: point, button: right ? .right : .left, flags: flags)
    for key in held.reversed() {
        flags.remove(key.flag)
        post(key: key.code, down: false, flags: flags)
    }
    if let pointer {
        CGWarpMouseCursorPosition(pointer)
    }
    return wait(for: { !Set(popups()).subtracting(before).isEmpty })
}

private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) {
    let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(20000)
}

private func post(key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(20000)
}

private func wait(for condition: () -> Bool) -> Bool {
    for _ in 0..<20 {
        if condition() {
            return true
        }
        usleep(50000)
    }
    return false
}

private func passClicks(at point: CGPoint) -> () -> Void {
    let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    let windows = NSApp.windows.filter { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(flipped) }
    for window in windows {
        window.ignoresMouseEvents = true
    }
    return { for window in windows {
        window.ignoresMouseEvents = false
    } }
}

private func popups() -> [CGWindowID] {
    let skipped = Set([getpid()] + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").map(\.processIdentifier))
    return WindowInfo.list([.optionOnScreenOnly])
        .filter { !skipped.contains($0.owner) && $0.layer > Int(CGWindowLevelForKey(.mainMenuWindow)) }
        .map(\.id)
}

private typealias CreateImage = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
private let createImage = privateSymbol(.windowListCreateImage, as: CreateImage.self)

private func capture(_ items: [TrayItem]) -> (paths: [String: String], error: String?) {
    guard CGPreflightScreenCaptureAccess() else { return ([:], missingGrant(.screenRecording, "tray icons")) }
    guard let createImage else { return ([:], "SLWindowListCreateImageFromArray is missing from SkyLight on this macOS") }
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier
    else { return (
        [:],
        "MenuBarAgent is not running",
    ) }
    let windows = WindowInfo.list([.optionAll]).compactMap { window -> (id: CGWindowID, bounds: CGRect)? in
        guard window.owner == agent, window.layer == Int(CGWindowLevelForKey(.mainMenuWindow)),
              let bounds = window.bounds, bounds.height <= 60 else { return nil }
        return (window.id, bounds)
    }
    let hosts = Dictionary(windows.map { ("\($0.bounds.origin)", $0) }, uniquingKeysWith: { $0.id > $1.id ? $0 : $1 }).values
    var paths: [String: String] = [:]
    for host in hosts {
        var pointer: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(host.id))
        var callbacks = CFArrayCallBacks(version: 0, retain: nil, release: nil, copyDescription: nil, equal: nil)
        guard let list = CFArrayCreate(nil, &pointer, 1, &callbacks),
              let image = createImage(.null, list, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() else { continue }
        let scale = CGFloat(image.width) / host.bounds.width
        for item in items where host.bounds.contains(CGPoint(x: item.element.frame.midX, y: item.element.frame.midY)) {
            let frame = item.element.frame.offsetBy(dx: -host.bounds.minX, dy: -host.bounds.minY)
            let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
            guard let icon = image.cropping(to: crop),
                  let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:]) else { continue }
            paths[item.id] = try? savePNG(png, in: "tray")
        }
    }
    return (paths, paths.isEmpty && !items.isEmpty ? "the menu bar could not be captured" : nil)
}
