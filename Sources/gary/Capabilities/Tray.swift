import AppKit
import ApplicationServices
import GaryCore
import GaryPrivate

private let trayQueue = DispatchQueue(label: "gary.tray", qos: .userInitiated)

extension Capability {
    static let tray = Capability(name: "tray", summary: "The status items in the menu bar, with their icons. Press one.", types: """
    declare namespace Gary {
      interface TrayItem {
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
      interface Host { tray: TrayApi }
      interface TrayApi {
        items(): Promise<{ items: TrayItem[]; iconError: string | null }>;
        press(id: string): Promise<TrayItem>;
      }
    }
    """, permissions: [.accessibility, .screenRecording], install: { host, plugin in
        plugin.installAPI(host, "tray", TrayRequest.methods) { call in
            let request = try TrayRequest.parse(call)
            return .later(trayQueue) {
                guard AXIsProcessTrusted() else { throw HostFailure(missingGrant("Accessibility", "the tray")) }
                switch request {
                case .items:
                    let items = try scan().map(\.item)
                    let icons = capture(items)
                    return .object([
                        "items": .array(items.map { $0.json(icon: icons.paths[$0.id]) }),
                        "iconError": icons.error.map(JSON.string) ?? .null,
                    ])
                case .press(let id):
                    guard let target = try scan().first(where: { $0.item.id == id }) else { throw HostFailure("no tray item \(id)") }
                    let result = AXUIElementPerformAction(target.press, kAXPressAction as CFString)
                    guard result == .success else { throw HostFailure("pressing \(id) failed with AXError \(result.rawValue)") }
                    return target.item.json(icon: nil)
                }
            }
        }
    })
}

private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

private func frame(_ element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}

private func scan() throws -> [(item: TrayItem, press: AXUIElement)] {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
        throw HostFailure("MenuBarAgent is not running")
    }
    let application = AXUIElementCreateApplication(agent.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 1)
    var elements: [TrayElement] = []
    var targets: [Int: AXUIElement] = [:]
    for window in children(application, kAXWindowsAttribute) {
        for group in children(window) {
            guard let child = children(group).first else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            let owner = NSRunningApplication(processIdentifier: pid)
            let button = attribute(child, kAXRoleAttribute) as? String == kAXButtonRole
            let element = TrayElement(
                frame: frame(group), app: owner?.bundleIdentifier ?? "pid:\(pid)", name: owner?.localizedName ?? "", pid: pid,
                title: button ? attribute(child, kAXTitleAttribute) as? String : nil,
                detail: button ? attribute(child, kAXDescriptionAttribute) as? String : nil
            )
            elements.append(element)
            let slot = Int(element.frame.minX.rounded())
            if button || targets[slot] == nil { targets[slot] = button ? child : group }
        }
    }
    return TrayItem.merge(elements).map { ($0, targets[Int($0.element.frame.minX.rounded())]!) }
}

private typealias CreateImage = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
private let createImage = privateSymbol(.windowListCreateImage, as: CreateImage.self)

private func capture(_ items: [TrayItem]) -> (paths: [String: String], error: String?) {
    guard CGPreflightScreenCaptureAccess() else { return ([:], missingGrant("Screen Recording", "tray icons")) }
    guard let createImage else { return ([:], "SLWindowListCreateImageFromArray is missing from SkyLight on this macOS") }
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier else { return ([:], "MenuBarAgent is not running") }
    let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info -> (id: CGWindowID, bounds: CGRect)? in
        guard info[kCGWindowOwnerPID as String] as? pid_t == agent,
              info[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.mainMenuWindow)),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = (info[kCGWindowBounds as String] as! CFDictionary?).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.height <= 60 else { return nil }
        return (id, bounds)
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
