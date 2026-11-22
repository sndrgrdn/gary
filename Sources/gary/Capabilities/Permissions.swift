import AppKit
import ApplicationServices
import CoreBluetooth
import EventKit
import GaryCore

extension Capability {
    static let permissions = Capability(
        name: "permissions",
        summary: """
        Each macOS permission, whether Gary has it, and the capabilities and enabled plugins that need it. \
        Ask for one, as gary permissions request does, or restart Gary through its crash supervisor \
        so a new Full Disk Access or Screen Recording grant takes effect. \
        After the restart Gary shows the calling plugin's surface again if it was open.
        """,
        types: """
        declare namespace Gary {
          type PermissionName = \(Permission.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | "));
          type PermissionStatus = {
            name: PermissionName;
            title: string;
            status: "granted" | "notAsked" | "denied" | "notGranted" | "needsRestart";
            restart: boolean;
            capabilities: { name: string; summary: string }[];
            plugins: { id: string; name: string; capabilities: string[] }[];
          }
          interface Host { permissions: { request(name: PermissionName): Promise<string>; restart(): Promise<string> } }
        }
        """,
        example: """
        export default {
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
        """,
        install: { host, plugin in
            plugin.installAPI(host, "permissions", PermissionsRequest.methods) { call in
                switch try PermissionsRequest.parse(call) {
                case let .request(permission): return .later(.main) { .string(permission.request()) }
                case .restart:
                    guard isSupervised
                    else { throw HostFailure("Gary runs without its crash supervisor, as with gary app, so it cannot restart itself") }
                    let id = plugin.id
                    return .later(.main) {
                        NotificationCenter.default.post(name: .restartGary, object: id)
                        return .string("restarting Gary")
                    }
                }
            }
        },
        topic: CapabilityTopic(type: "PermissionStatus[]") { PermissionsTopic($0) },
    )
}

extension Notification.Name {
    static let restartGary = Notification.Name("GaryRestart")
}

private final class PermissionsTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private var observation: Observation?
    private var grantedSinceStart: Set<Permission> = []
    private var probing = false
    private var checking = false
    private let checks = DispatchQueue(label: "gary.permissions", qos: .utility)

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        send(Trace("permissions-start"))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.send(Trace("permissions")) }
        RunLoop.main.add(timer, forMode: .common)
        observation = Observation { timer.invalidate() }
    }

    private func send(_ trace: Trace) {
        guard !checking else { return }
        checking = true
        let enabled = PermissionNeed.enabledPlugins
        let location = Permission.location.grant
        checks.async { [weak self] in
            var needs = PermissionNeed.all(enabled: enabled, checkGrants: false)
            for index in needs.indices {
                let permission = needs[index].permission
                needs[index].grant = permission == .location ? location : permission.grant
            }
            DispatchQueue.main.async {
                self?.checking = false
                self?.deliver(needs, trace)
            }
        }
    }

    private func deliver(_ checked: [PermissionNeed], _ trace: Trace) {
        var needs = checked
        for index in needs.indices where needs[index].grant != .granted && grantedSinceStart.contains(needs[index].permission) {
            needs[index].grant = .needsRestart
        }
        publish(.array(needs.map(\.json)), trace)
        probe(needs.filter { $0.permission.needsRestart && $0.grant != .granted && $0.grant != .needsRestart }.map(\.permission))
    }

    private func probe(_ permissions: [Permission]) {
        guard !permissions.isEmpty, !probing else { return }
        probing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let granted = freshGrants(permissions)
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard !granted.isSubset(of: self.grantedSinceStart) else { return }
                self.grantedSinceStart.formUnion(granted)
                self.send(Trace("permissions-granted"))
            }
        }
    }
}

let grantProbeVerb = "grant-probe"

func freshGrants(_ permissions: [Permission]) -> Set<Permission> {
    let process = Process()
    process.executableURL = Bundle.main.executableURL
    process.arguments = [grantProbeVerb] + permissions.map(\.rawValue)
    let output = Pipe()
    process.standardOutput = output
    guard (try? process.run()) != nil else { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let names = String(bytes: data, encoding: .utf8)?.split(separator: "\n") ?? []
    return Set(names.compactMap { Permission(rawValue: String($0)) })
}

func runGrantProbe(_ names: [String]) -> Int32 {
    for permission in names.compactMap(Permission.init(rawValue:)) where permission.grant == .granted {
        print(permission.rawValue)
    }
    return 0
}

enum Grant: String {
    case granted, notAsked, denied, notGranted, needsRestart

    var description: String {
        switch self {
        case .granted: "granted"
        case .notAsked: "not asked"
        case .denied: "denied"
        case .notGranted: "not granted"
        case .needsRestart: "granted, takes effect after a restart"
        }
    }
}

struct PermissionNeed {
    static var enabledPlugins: [PluginManifest] = []

    let permission: Permission
    var grant: Grant?
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
        let users = plugins.isEmpty ? "no enabled plugin" : plugins.map { "\($0.manifest.id) (\($0.capabilities.joined(separator: ", ")))" }
            .joined(separator: ", ")
        return "needed by \(capabilities.joined(separator: ", ")); used by \(users)"
    }

    var isMissing: Bool {
        grant != .granted && !plugins.isEmpty
    }

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
                .object([
                    "id": .string(plugin.manifest.id.rawValue),
                    "name": .string(plugin.manifest.name),
                    "capabilities": .array(plugin.capabilities.map(JSON.string)),
                ])
            }),
        ])
    }
}

extension Permission {
    var needsRestart: Bool {
        self == .screenRecording || self == .fullDiskAccess
    }

    private static let preview: [Permission: Grant] = {
        let text = ProcessInfo.processInfo.environment["GARY_PERMISSIONS_PREVIEW"] ?? ""
        return Dictionary(text.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let permission = Permission(rawValue: parts[0]), let grant = Grant(rawValue: parts[1]) else { return nil }
            return (permission, grant)
        }) { $1 }
    }()

    var grant: Grant {
        Self.preview[self] ?? systemGrant
    }

    private var systemGrant: Grant {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .automation:
            switch loginWindowConsent(ask: false) {
            case noErr: return .granted
            case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .notGranted
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notAsked
            case .writeOnly: return .notGranted
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
                if descriptor >= 0 {
                    close(descriptor); return .granted
                }
                if errno == EPERM || errno == EACCES {
                    return .notGranted
                }
            }
            return .notGranted
        case .location:
            switch LocationAccess.shared.status {
            case "authorized": return .granted
            case "notDetermined": return .notAsked
            default: return .denied
            }
        case .notifications:
            switch NotificationPoster.authorization {
            case .authorized, .provisional: return .granted
            case .notDetermined: return .notAsked
            case .denied: return .denied
            default: return .notGranted
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        }
    }

    func request() -> String {
        let pane = "System Settings > Privacy & Security > \(name)"
        let current = grant
        guard current != .granted else { return "Gary already has \(name)" }
        guard current != .needsRestart else { return "Gary has \(name) once it restarts" }
        switch self {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            return "macOS shows its Accessibility prompt for Gary. Choose Open System Settings and turn Gary on in \(pane)."
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(settingsPane)
            return "asked macOS for Screen Recording and opened \(pane). Turn Gary on there, then quit and reopen Gary."
        case .automation, .location, .bluetooth, .calendars, .notifications:
            guard current == .notAsked else {
                NSWorkspace.shared.open(settingsPane)
                return "Gary was refused \(name) before, so macOS shows no prompt. Opened \(pane). Turn Gary on there."
            }
            switch self {
            case .location: LocationAccess.shared.request()
            case .calendars: CalendarStore.request()
            case .notifications: NotificationPoster.request()
            case .automation: DispatchQueue.global(qos: .userInitiated).async { _ = loginWindowConsent(ask: true) }
            default: BluetoothAccess.shared.request()
            }
            return "macOS shows its \(name) prompt for Gary. Choose Allow."
        case .fullDiskAccess:
            NSWorkspace.shared.open(settingsPane)
            AppDragTile.show(until: .fullDiskAccess)
            return "macOS has no prompt for Full Disk Access. Opened \(pane) and showed Gary's icon to drag into its list. Turn Gary on there, then restart Gary."
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
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return "pid \(pid)" }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

func permissionReport(enabled manifests: [PluginManifest]) -> String {
    var lines = ["Gary \(Bundle.main.bundleIdentifier ?? "without a bundle id") at \(Bundle.main.bundlePath), pid \(getpid())"]
    if let program = launchingProgram() {
        lines
            .append(
                "warning: \(program) started this Gary, so macOS checks that program's permissions instead of Gary's. Start Gary with: open \(Bundle.main.bundlePath)",
            )
    }
    lines.append("")
    let needs = PermissionNeed.all(enabled: manifests, checkGrants: true)
    let width = needs.map(\.permission.rawValue.count).max() ?? 0
    for need in needs {
        let grant = (need.grant ?? .notAsked).description
        lines.append(need.permission.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + grant.padding(
            toLength: 13,
            withPad: " ",
            startingAt: 0,
        ) + need.summary)
    }
    let wanted = needs.filter(\.isMissing).map(\.permission.rawValue)
    if !wanted.isEmpty {
        lines += ["", "Enabled plugins need: " + wanted.map { "gary permissions request \($0)" }.joined(separator: "; ")]
    }
    return lines.joined(separator: "\n")
}
