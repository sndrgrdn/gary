import ApplicationServices
import CoreBluetooth
import CoreLocation
import Foundation
import GaryCore
import GaryPrivate
import GarySocket
import UserNotifications

struct PrivateSymbolCheck {
    let library: String
    let symbol: String
    let feature: String
    let resolved: Bool

    static func all() -> [PrivateSymbolCheck] {
        (0..<gary_private_symbol_count()).map { index in
            let entry = gary_private_symbol(index)
            return PrivateSymbolCheck(
                library: String(cString: entry.library), symbol: String(cString: entry.symbol),
                feature: String(cString: entry.feature), resolved: gary_private_resolve(index) != nil
            )
        }
    }

    static func summary() -> String {
        let checks = all()
        let missing = checks.filter { !$0.resolved }.map { "\($0.symbol) (\($0.feature))" }
        return "private api: \(checks.count - missing.count) of \(checks.count) symbols resolved" + (missing.isEmpty ? "" : "; missing " + missing.joined(separator: ", "))
    }
}

extension Permission {
    var name: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .bluetooth: return "Bluetooth"
        case .fullDiskAccess: return "Full Disk Access"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .screenRecording: return "Screen Recording"
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .bluetooth:
            return CBManager.authorization == .allowedAlways
        case .fullDiskAccess:
            let database = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
            let fd = open(database.path, O_RDONLY)
            defer { if fd >= 0 { close(fd) } }
            return fd >= 0
        case .location:
            return [.authorizedAlways, .authorized].contains(CLLocationManager().authorizationStatus)
        case .notifications:
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var status = UNAuthorizationStatus.notDetermined
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                status = settings.authorizationStatus
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
            return [.authorized, .provisional].contains(status)
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        }
    }
}

struct DoctorRuntime {
    var pid: Int32
    var capabilities: Set<String>
    var pluginStates: [(plugin: String, problem: String?)]
}

struct Doctor {
    private var lines: [String] = []
    private var problems = 0

    private mutating func section(_ title: String) { lines.append("\n\(title)") }
    private mutating func ok(_ text: String) { lines.append("  ok    \(text)") }
    private mutating func info(_ text: String) { lines.append("  -     \(text)") }
    private mutating func fail(_ text: String) {
        problems += 1
        lines.append("  FAIL  \(text)")
    }

    static func report(_ runtime: DoctorRuntime?) -> String {
        var doctor = Doctor()
        doctor.build(runtime)
        return doctor.lines.joined(separator: "\n")
    }

    private mutating func build(_ runtime: DoctorRuntime?) {
        let bundle = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("Gary \(bundle?["CFBundleShortVersionString"] as? String ?? "dev") (\(bundle?["CFBundleVersion"] as? String ?? "0")) at \(Bundle.main.bundlePath)")
        lines.append("macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(ProcessInfo.processInfo.operatingSystemVersionString))")
        lines.append(runtime.map { "running as pid \($0.pid)" } ?? "not running; checks below read the files on disk")

        section("Window levels")
        let levels = SurfaceLevels.forSystem(version)
        info("bar \(levels.bar)")
        for layer in SurfaceLayer.allCases { info("\(layer.rawValue) \(levels.level(layer))") }

        section("Private API")
        for check in PrivateSymbolCheck.all() {
            if check.resolved { ok("\(check.symbol) for \(check.feature)") } else { fail("\(check.symbol) missing from \(check.library); \(check.feature) is off") }
        }

        section("Permissions")
        if let runtime {
            let needed = Capability.all.filter { runtime.capabilities.contains($0.name) && $0.permission != nil }
            if needed.isEmpty { info("no enabled capability needs a permission") }
            for capability in needed {
                let permission = capability.permission!
                if permission.isGranted { ok("\(permission.name) for \(capability.name)") } else { fail("\(permission.name) not granted; \(capability.name) needs it") }
            }
            for permission in Permission.allCases where !needed.contains(where: { $0.permission == permission }) {
                info("\(permission.name) \(permission.isGranted ? "granted" : "not granted"), not needed")
            }
        } else {
            info("unknown: macOS answers for the process that asks, so run Gary and ask again")
        }

        section("Plugins")
        guard let capabilities = try? Capability.names() else { return fail("the capability registry is invalid") }
        let catalog = PluginCatalog.scan(builtin: Paths.builtinPlugins, user: Paths.userPlugins, capabilities: capabilities)
        ok("\(catalog.plugins.count) found")
        for problem in catalog.problems { fail("\(problem.directory.path): \(problem.reason)") }
        for state in runtime?.pluginStates ?? [] {
            if let problem = state.problem { fail("\(state.plugin): \(problem)") }
        }

        section("Config")
        checkConfig(catalog)
        checkTheme()

        lines.append("\n\(problems == 0 ? "no problems" : "\(problems) problem\(problems == 1 ? "" : "s")")")
    }

    private mutating func checkConfig(_ catalog: PluginCatalog) {
        guard FileManager.default.fileExists(atPath: Paths.shellConfig.path) else { return info("no shell.json; using defaults") }
        do {
            let config = try ShellConfig.parse(try JSON.parse(Data(contentsOf: Paths.shellConfig)))
            let warnings = config.resolve(catalog).warnings
            if warnings.isEmpty { ok("shell.json") }
            for warning in warnings { fail("shell.json: \(warning)") }
        } catch {
            fail("shell.json: \(error)")
        }
    }

    private mutating func checkTheme() {
        var file: PaletteFile?
        if FileManager.default.fileExists(atPath: Paths.palette.path) {
            do {
                file = PaletteFile.parse(try String(contentsOf: Paths.palette, encoding: .utf8))
                if file!.ignored.isEmpty { ok("palette.toml") }
                for problem in file!.ignored { fail("palette.toml: \(problem)") }
            } catch {
                fail("palette.toml: \(error)")
            }
        } else {
            info("no palette.toml; following the system appearance")
        }
        do {
            let override = FileManager.default.fileExists(atPath: Paths.userTheme.path) ? try JSON.parse(Data(contentsOf: Paths.userTheme)) : nil
            let theme = try Theme.parse(try JSON.parse(Data(contentsOf: Paths.defaultTheme)), override: override, palette: Palette(file, system: .dark))
            if theme.warnings.isEmpty { ok(override == nil ? "built-in theme" : "theme.json") }
            for warning in theme.warnings { fail("theme: \(warning)") }
        } catch {
            fail("theme: \(error)")
        }
    }
}

func runDoctor() -> Int32 {
    do {
        switch try Response.decode(line: try requestLine(Request.doctor.line, path: socketPath, timeout: 10)) {
        case .ok(let report): print(report)
        case .failure(let message): print("gary: \(message)")
        }
    } catch SocketError.unreachable {
        print(Doctor.report(nil))
    } catch {
        print("gary: \(error); reading the files on disk instead\n")
        print(Doctor.report(nil))
    }
    return 0
}
