import Foundation

public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case audioCapture = "audio-capture"
    case automation
    case bluetooth
    case calendars
    case fullDiskAccess = "full-disk-access"
    case location
    case notifications
    case screenRecording = "screen-recording"

    public var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .audioCapture: "System Audio Recording"
        case .automation: "Automation"
        case .bluetooth: "Bluetooth"
        case .calendars: "Calendars"
        case .fullDiskAccess: "Full Disk Access"
        case .location: "Location"
        case .notifications: "Notifications"
        case .screenRecording: "Screen Recording"
        }
    }

    public var settingsPane: URL {
        let privacy = "com.apple.preference.security?Privacy_"
        let pane = switch self {
        case .accessibility: privacy + "Accessibility"
        case .audioCapture: privacy + "AudioCapture"
        case .automation: privacy + "Automation"
        case .bluetooth: privacy + "Bluetooth"
        case .calendars: privacy + "Calendars"
        case .fullDiskAccess: privacy + "AllFiles"
        case .location: privacy + "LocationServices"
        case .notifications: "com.apple.Notifications-Settings.extension?id=com.sndrgrdn.gary"
        case .screenRecording: privacy + "ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:\(pane)") ?? URL(filePath: "/System/Applications/System Settings.app")
    }
}

public enum PermissionsRequest: Equatable, Sendable {
    case request(Permission)
    case restart

    public static let methods = ["request", "restart"]

    public static func parse(_ call: HostCall) throws -> PermissionsRequest {
        if call.method == "restart" {
            return .restart
        }
        guard call.method == "request" else { throw call.unknownMethod }
        let name = try call.string(0, "name")
        guard let permission = Permission(rawValue: name) else {
            throw call.fail("name must be " + Permission.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
        }
        return .request(permission)
    }
}
