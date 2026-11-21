import AppKit
import ApplicationServices
import CoreBluetooth
import GaryCore

enum Grant: String {
    case granted
    case notAsked = "not asked"
    case denied
    case missing = "not granted"
}

struct PermissionNeed {
    let permission: Permission
    let grant: Grant?
    let capabilities: [String]
    let plugins: [(id: PluginID, capabilities: [String])]

    static func all(enabled manifests: [PluginManifest], checkGrants: Bool) -> [PermissionNeed] {
        Permission.allCases.map { permission in
            let capabilities = Capability.all.filter { $0.permissions.contains(permission) }.map(\.name)
            let plugins = manifests.sorted { $0.id < $1.id }.compactMap { manifest -> (PluginID, [String])? in
                let needing = manifest.capabilities.filter(capabilities.contains)
                return needing.isEmpty ? nil : (manifest.id, needing)
            }
            return PermissionNeed(permission: permission, grant: checkGrants ? permission.grant : nil, capabilities: capabilities, plugins: plugins)
        }
    }

    var summary: String {
        let users = plugins.isEmpty ? "no enabled plugin" : plugins.map { "\($0.id) (\($0.capabilities.joined(separator: ", ")))" }.joined(separator: ", ")
        return "needed by \(capabilities.joined(separator: ", ")); used by \(users)"
    }
}

extension Permission {
    var grant: Grant {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .missing
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .fullDiskAccess:
            let descriptor = open(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path, O_RDONLY)
            defer { if descriptor >= 0 { close(descriptor) } }
            return descriptor >= 0 ? .granted : .missing
        case .location:
            switch LocationAccess.shared.status {
            case "authorized": return .granted
            case "notDetermined": return .notAsked
            default: return .denied
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .missing
        }
    }

    func request() -> String {
        let pane = "System Settings > Privacy & Security > \(name)"
        let current = grant
        guard current != .granted else { return "Gary already has \(name)" }
        switch self {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            return "macOS shows its Accessibility prompt for Gary. Choose Open System Settings and turn Gary on in \(pane)."
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(settingsPane)
            return "asked macOS for Screen Recording and opened \(pane). Turn Gary on there, then quit and reopen Gary."
        case .location, .bluetooth:
            guard current == .notAsked else {
                NSWorkspace.shared.open(settingsPane)
                return "Gary was refused \(name) before, so macOS shows no prompt. Opened \(pane). Turn Gary on there."
            }
            if self == .location { LocationAccess.shared.request() } else { BluetoothAccess.shared.request() }
            return "macOS shows its \(name) prompt for Gary. Choose Allow."
        case .fullDiskAccess:
            NSWorkspace.shared.open(settingsPane)
            return "macOS has no prompt for Full Disk Access. Opened \(pane). Turn Gary on there, or add \(Bundle.main.bundlePath) with the + button, then quit and reopen Gary."
        }
    }
}

func launchingProgram() -> String? {
    var pid = getppid()
    while pid > 1 {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "pid \(pid)" }
        let program = String(cString: path)
        guard program == Bundle.main.executablePath else { return URL(fileURLWithPath: program).lastPathComponent }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return "pid \(pid)" }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

func permissionReport(enabled manifests: [PluginManifest]) -> String {
    var lines = ["Gary \(Bundle.main.bundleIdentifier ?? "without a bundle id") at \(Bundle.main.bundlePath), pid \(getpid())"]
    if let program = launchingProgram() {
        lines.append("warning: \(program) started this Gary, so macOS checks that program's permissions instead of Gary's. Start Gary with: open \(Bundle.main.bundlePath)")
    }
    lines.append("")
    let needs = PermissionNeed.all(enabled: manifests, checkGrants: true)
    let width = Permission.allCases.map(\.rawValue.count).max()!
    for need in needs {
        let grant = need.grant!.rawValue
        lines.append(need.permission.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + grant.padding(toLength: 13, withPad: " ", startingAt: 0) + need.summary)
    }
    let wanted = needs.filter { $0.grant != .granted && !$0.plugins.isEmpty }.map(\.permission.rawValue)
    if !wanted.isEmpty { lines += ["", "Enabled plugins need: " + wanted.map { "gary permissions request \($0)" }.joined(separator: "; ")] }
    return lines.joined(separator: "\n")
}
