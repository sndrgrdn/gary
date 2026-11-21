import Foundation
import GaryCore
import GaryPrivate
import GarySocket

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
                feature: String(cString: entry.feature), resolved: gary_private_resolve(index) != nil,
            )
        }
    }

    static func summary() -> String {
        let checks = all()
        let missing = checks.filter { !$0.resolved }.map { "\($0.symbol) (\($0.feature))" }
        return "private api: \(checks.count - missing.count) of \(checks.count) symbols resolved" +
            (missing.isEmpty ? "" : "; missing " + missing.joined(separator: ", "))
    }
}

struct DoctorRuntime {
    var pid: Int32
    var enabled: [PluginManifest]
    var pluginStates: [(plugin: String, problem: String?)]
}

struct Doctor {
    private var lines: [String] = []
    private var problems = 0

    private mutating func section(_ title: String) {
        lines.append("\n\(title)")
    }

    private mutating func ok(_ text: String) {
        lines.append("  ok    \(text)")
    }

    private mutating func info(_ text: String) {
        lines.append("  -     \(text)")
    }

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
        let version = ProcessInfo.processInfo.operatingSystemVersion
        describeBuild(version, runtime)

        section("Window levels")
        listWindowLevels(version)

        section("Private API")
        checkPrivateSymbols()

        section("Permissions")
        checkPermissions(runtime)

        section("Plugins")
        guard let catalog = checkPlugins(runtime) else { return }

        section("Config")
        checkConfig(catalog)
        checkTheme()

        lines.append("\n\(problems == 0 ? "no problems" : "\(problems) problem\(problems == 1 ? "" : "s")")")
    }

    private mutating func describeBuild(_ version: OperatingSystemVersion, _ runtime: DoctorRuntime?) {
        let bundle = Bundle.main.infoDictionary
        lines
            .append(
                "Gary \(bundle?["CFBundleShortVersionString"] as? String ?? "dev") (\(bundle?["CFBundleVersion"] as? String ?? "0")) at \(Bundle.main.bundlePath)",
            )
        lines
            .append(
                "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(ProcessInfo.processInfo.operatingSystemVersionString))",
            )
        lines.append(runtime.map { "running as pid \($0.pid)" } ?? "not running; checks below read the files on disk")
    }

    private mutating func listWindowLevels(_ version: OperatingSystemVersion) {
        let levels = SurfaceLevels.forSystem(version)
        info("bar \(levels.bar), and \(levels.barAside) while the macOS menu bar is revealed")
        for layer in SurfaceLayer.allCases {
            info("\(layer.rawValue) \(levels.level(layer))")
        }
    }

    private mutating func checkPrivateSymbols() {
        for check in PrivateSymbolCheck.all() {
            if check.resolved {
                ok("\(check.symbol) for \(check.feature)")
            } else {
                fail("\(check.symbol) missing from \(check.library); \(check.feature) is off")
            }
        }
    }

    private mutating func checkPermissions(_ runtime: DoctorRuntime?) {
        if runtime == nil {
            info("grants unknown: macOS answers for the process that asks, so run Gary and ask again")
        }
        if runtime != nil,
           let program = launchingProgram()
        {
            fail("\(program) started Gary, so macOS checks \(program)'s permissions instead of Gary's")
        }
        for need in PermissionNeed.all(enabled: runtime?.enabled ?? [], checkGrants: runtime != nil) {
            let line = "\(need.permission.name)" + (need.grant.map { " \($0.description)" } ?? "") + "; \(need.summary)"
            if need.plugins.isEmpty || need.grant == nil {
                info(line)
            } else if need.grant == .granted {
                ok(line)
            } else {
                fail(line + "; run gary permissions request \(need.permission.rawValue)")
            }
        }
    }

    private mutating func checkPlugins(_ runtime: DoctorRuntime?) -> PluginCatalog? {
        guard let capabilities = try? Capability.names() else { fail("the capability registry is invalid")
            return nil
        }
        let catalog = PluginCatalog.scan(builtin: Paths.builtinPlugins, user: Paths.userPlugins, capabilities: capabilities)
        ok("\(catalog.plugins.count) found")
        for problem in catalog.problems {
            fail("\(problem.directory.path): \(problem.reason)")
        }
        for state in runtime?.pluginStates ?? [] {
            if let problem = state.problem {
                fail("\(state.plugin): \(problem)")
            }
        }
        return catalog
    }

    private mutating func checkConfig(_ catalog: PluginCatalog) {
        guard FileManager.default.fileExists(atPath: Paths.shellConfig.path) else { info("no shell.json; using defaults")
            return
        }
        do {
            let config = try ShellConfig.parse(JSON.parse(Data(contentsOf: Paths.shellConfig)))
            let warnings = config.resolve(catalog).warnings
            if warnings.isEmpty {
                ok("shell.json")
            }
            for warning in warnings {
                fail("shell.json: \(warning)")
            }
        } catch {
            fail("shell.json: \(error)")
        }
    }

    private mutating func checkPalette() -> PaletteFile? {
        guard FileManager.default.fileExists(atPath: Paths.palette.path) else {
            info("no palette.toml; following the system appearance")
            return nil
        }
        do {
            let file = try PaletteFile.parse(String(contentsOf: Paths.palette, encoding: .utf8))
            if file.ignored.isEmpty {
                ok("palette.toml")
            }
            for problem in file.ignored {
                fail("palette.toml: \(problem)")
            }
            return file
        } catch {
            fail("palette.toml: \(error)")
            return nil
        }
    }

    private mutating func checkTheme() {
        let file = checkPalette()
        do {
            let override = FileManager.default.fileExists(atPath: Paths.userTheme.path) ? try JSON.parse(Data(contentsOf: Paths.userTheme)) : nil
            let theme = try Theme.parse(JSON.parse(Data(contentsOf: Paths.defaultTheme)), override: override, palette: Palette(file, system: .dark))
            if theme.warnings.isEmpty {
                ok(override == nil ? "built-in theme" : "theme.json")
            }
            for warning in theme.warnings {
                fail("theme: \(warning)")
            }
        } catch {
            fail("theme: \(error)")
        }
    }
}

func runDoctor() -> Int32 {
    do {
        switch try Response.decode(line: requestLine(Request.doctor.line, path: socketPath, timeout: 10)) {
        case let .ok(report): print(report)
        case let .failure(message): print("gary: \(message)")
        }
    } catch SocketError.unreachable {
        print(Doctor.report(nil))
    } catch {
        print("gary: \(error); reading the files on disk instead\n")
        print(Doctor.report(nil))
    }
    return 0
}
