import AppKit
import ApplicationServices
import CoreBluetooth
import GaryCore

extension Capability {
    static let permissions = Capability(name: "permissions", summary: "Each macOS permission, whether Gary has it, and the capabilities and enabled plugins that need it. Ask for one, as gary permissions request does.", types: """
    declare namespace Gary {
      type PermissionName = \(Permission.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | "));
      interface State { permissions?: PermissionStatus[] }
      interface PermissionStatus {
        name: PermissionName;
        title: string;
        status: "granted" | "notAsked" | "denied" | "notGranted";
        restart: boolean;
        capabilities: { name: string; summary: string }[];
        plugins: { id: string; name: string; capabilities: string[] }[];
      }
      interface Host { permissions: { request(name: PermissionName): Promise<string> } }
    }
    """, example: """
    module.exports = {
      render(state) {
        const missing = (state.permissions ?? []).filter((each) => each.plugins.length > 0 && each.status !== "granted");
        return {
          type: "column",
          children: missing.map((each) => ({
            type: "button", key: each.name, action: each.name,
            children: [{ type: "text", text: `Grant ${each.title} for ${each.plugins.map((plugin) => plugin.name).join(", ")}` }],
          })),
        };
      },
      onAction(name, _payload, state) {
        const permission = state.permissions?.find((each) => each.name === name);
        if (permission) host.permissions.request(permission.name).then((message) => host.log(message));
      },
    } satisfies Gary.Panel;
    """, install: { host, plugin in
        plugin.installAPI(host, "permissions", PermissionsRequest.methods) { call in
            switch try PermissionsRequest.parse(call) {
            case .request(let permission): return .later(.main) { .string(permission.request()) }
            }
        }
    }, topic: { PermissionsTopic($0) })
}

private final class PermissionsTopic {
    private let publish: (JSON, Trace) -> Void
    private var observation: Observation?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        send(Trace("permissions-start"))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.send(Trace("permissions")) }
        RunLoop.main.add(timer, forMode: .common)
        observation = Observation { timer.invalidate() }
    }

    private func send(_ trace: Trace) {
        publish(.array(PermissionNeed.all(enabled: PermissionNeed.enabledPlugins, checkGrants: true).map(\.json)), trace)
    }
}

enum Grant: String {
    case granted, notAsked, denied, notGranted

    var description: String {
        switch self {
        case .granted: return "granted"
        case .notAsked: return "not asked"
        case .denied: return "denied"
        case .notGranted: return "not granted"
        }
    }
}

struct PermissionNeed {
    static var enabledPlugins: [PluginManifest] = []

    let permission: Permission
    let grant: Grant?
    let capabilities: [String]
    let plugins: [(manifest: PluginManifest, capabilities: [String])]

    static func all(enabled manifests: [PluginManifest], checkGrants: Bool) -> [PermissionNeed] {
        Permission.allCases.map { permission in
            let capabilities = Capability.all.filter { $0.permissions.contains(permission) }.map(\.name)
            let plugins = manifests.sorted { $0.id < $1.id }.compactMap { manifest -> (PluginManifest, [String])? in
                let needing = manifest.capabilities.filter(capabilities.contains)
                return needing.isEmpty ? nil : (manifest, needing)
            }
            return PermissionNeed(permission: permission, grant: checkGrants ? permission.grant : nil, capabilities: capabilities, plugins: plugins)
        }
    }

    var summary: String {
        let users = plugins.isEmpty ? "no enabled plugin" : plugins.map { "\($0.manifest.id) (\($0.capabilities.joined(separator: ", ")))" }.joined(separator: ", ")
        return "needed by \(capabilities.joined(separator: ", ")); used by \(users)"
    }

    var isMissing: Bool { grant != .granted && !plugins.isEmpty }

    var json: JSON {
        .object([
            "name": .string(permission.rawValue),
            "title": .string(permission.name),
            "status": .string((grant ?? .notAsked).rawValue),
            "restart": .bool(permission.needsRestart),
            "capabilities": .array(capabilities.map { name in
                .object(["name": .string(name), "summary": .string(Capability.all.first { $0.name == name }?.summary ?? "")])
            }),
            "plugins": .array(plugins.map { plugin in
                .object(["id": .string(plugin.manifest.id.rawValue), "name": .string(plugin.manifest.name), "capabilities": .array(plugin.capabilities.map(JSON.string))])
            }),
        ])
    }
}

extension Permission {
    var needsRestart: Bool { self == .screenRecording || self == .fullDiskAccess }

    var grant: Grant {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .fullDiskAccess:
            let home = FileManager.default.homeDirectoryForCurrentUser
            let probes = [
                "Library/Group Containers/group.com.apple.usernoted/db2/db",
                "Library/Safari/Bookmarks.plist",
                "Library/Application Support/com.apple.TCC/TCC.db",
            ]
            for probe in probes {
                let descriptor = open(home.appending(path: probe).path, O_RDONLY)
                if descriptor >= 0 { close(descriptor); return .granted }
                if errno == EPERM || errno == EACCES { return .notGranted }
            }
            return .notGranted
        case .location:
            switch LocationAccess.shared.status {
            case "authorized": return .granted
            case "notDetermined": return .notAsked
            default: return .denied
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
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
        let grant = need.grant!.description
        lines.append(need.permission.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + grant.padding(toLength: 13, withPad: " ", startingAt: 0) + need.summary)
    }
    let wanted = needs.filter(\.isMissing).map(\.permission.rawValue)
    if !wanted.isEmpty { lines += ["", "Enabled plugins need: " + wanted.map { "gary permissions request \($0)" }.joined(separator: "; ")] }
    return lines.joined(separator: "\n")
}
