import Foundation

public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case bluetooth
    case fullDiskAccess = "full-disk-access"
    case location
    case screenRecording = "screen-recording"

    public var name: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .bluetooth: return "Bluetooth"
        case .fullDiskAccess: return "Full Disk Access"
        case .location: return "Location"
        case .screenRecording: return "Screen Recording"
        }
    }

    public var hasPrompt: Bool { self != .fullDiskAccess }

    public var settingsPane: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .location: anchor = "Privacy_LocationServices"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
