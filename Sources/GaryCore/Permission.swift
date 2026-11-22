import Foundation

public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case bluetooth
    case calendars
    case fullDiskAccess = "full-disk-access"
    case location
    case screenRecording = "screen-recording"

    public var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .bluetooth: "Bluetooth"
        case .calendars: "Calendars"
        case .fullDiskAccess: "Full Disk Access"
        case .location: "Location"
        case .screenRecording: "Screen Recording"
        }
    }

    public var settingsPane: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .bluetooth: "Privacy_Bluetooth"
        case .calendars: "Privacy_Calendars"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .location: "Privacy_LocationServices"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            ?? URL(filePath: "/System/Applications/System Settings.app")
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
