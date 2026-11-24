import AppKit
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

private let otherBars = ["sketchybar": "SketchyBar", "stablebar": "StableBar", "übersicht": "Übersicht", "zebar": "Zebar", "barik": "Barik"]

private func runningOtherBars() -> [String] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var name = [UInt8](repeating: 0, count: 64)
    var found: Set<String> = []
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 {
        if let bar = otherBars[String(decoding: name.prefix { $0 != 0 }, as: UTF8.self).lowercased()] {
            found.insert(bar)
        }
    }
    return found.sorted()
}

struct DoctorRuntime {
    var pid: Int32
    var enabled: [PluginManifest]
    var pluginStates: [(plugin: String, problem: String?)]
    var themePayload: JSON?
    var grants: [Permission: Grant] = [:]
    var supervised = isSupervised
    var allocatorZones = mallocZoneNames()
}

private let systemAllocatorZone = "WebKit Using System Malloc"

nonisolated func mallocZoneNames() -> [String] {
    var addresses: UnsafeMutablePointer<vm_address_t>?
    var count: UInt32 = 0
    guard malloc_get_all_zones(mach_task_self_, nil, &addresses, &count) == KERN_SUCCESS, let addresses else { return [] }
    return (0..<Int(count)).compactMap { index in
        UnsafeMutablePointer<malloc_zone_t>(bitPattern: addresses[index]).flatMap { malloc_get_zone_name($0) }.map { String(cString: $0) }
    }
}

struct Doctor {
    private let files: ConfigFiles
    private let system: Palette.Mode
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

    static func report(_ runtime: DoctorRuntime?, system: Palette.Mode, files: ConfigFiles = ConfigFiles()) -> String {
        var doctor = Doctor(files: files, system: system)
        doctor.build(runtime)
        return doctor.lines.joined(separator: "\n")
    }

    private mutating func build(_ runtime: DoctorRuntime?) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        describeBuild(version, runtime)

        section("Private API")
        checkPrivateSymbols()

        if let runtime {
            section("Memory")
            checkAllocator(runtime)
        }

        section("Permissions")
        checkPermissions(runtime)

        section("Plugins")
        let config = Result { try files.config() }
        let catalog = checkPlugins(runtime, packages: (try? config.get())?.packages ?? [])

        section("Other bars")
        checkOtherBars()

        section("Config")
        checkConfig(config, catalog)
        checkTheme(override: runtime?.themePayload)

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

    private mutating func checkPrivateSymbols() {
        for check in PrivateSymbolCheck.all() {
            if check.resolved {
                ok("\(check.symbol) for \(check.feature)")
            } else {
                fail("\(check.symbol) missing from \(check.library); \(check.feature) is off")
            }
        }
    }

    private mutating func checkAllocator(_ runtime: DoctorRuntime) {
        if runtime.allocatorZones.contains(systemAllocatorZone) {
            ok("JavaScriptCore runs on the system allocator")
        } else if runtime.supervised {
            fail("JavaScriptCore runs on its own allocator, so Gary uses about 4 MB more; it started before Gary could set Malloc=1 for it")
        } else {
            info("JavaScriptCore runs on its own allocator, which uses about 4 MB more, since this Gary runs without its supervisor")
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
        for need in PermissionNeed.all(enabled: runtime?.enabled ?? [], grants: runtime?.grants) {
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

    private mutating func checkPlugins(_ runtime: DoctorRuntime?, packages: [PackageSource]) -> PluginCatalog {
        let catalog = files.catalog(packages)
        for source in packages where !PackageStore.isInstalled(source) {
            fail("package \(source.declaration) is not installed; run gary plugin update")
        }
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

    private mutating func checkOtherBars() {
        let bars = runningOtherBars()
        if bars.isEmpty {
            ok("none running")
        }
        for bar in bars {
            fail("\(bar) is running and can draw its own bar over Gary's; quit it")
        }
    }

    private mutating func checkConfig(_ config: Result<ShellConfig?, any Error>, _ catalog: PluginCatalog) {
        do {
            guard let config = try config.get() else {
                info("no shell.json; using defaults")
                return
            }
            let resolution = config.resolve(catalog)
            let warnings = config.warnings.map(\.description) + resolution.warnings.map { "shell.json: \($0)" }
            if warnings.isEmpty {
                ok("shell.json")
            }
            for warning in warnings {
                fail(warning)
            }
            for note in resolution.notes {
                info("shell.json: \(note)")
            }
        } catch {
            fail("shell.json: \(error)")
        }
    }

    private mutating func checkPalette() -> PaletteFile? {
        do {
            guard let file = try files.paletteFile() else {
                info("no palette.toml; following the system appearance")
                return nil
            }
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

    private mutating func checkTheme(override: JSON?) {
        let file = checkPalette()
        do {
            let theme = try files.theme(palette: file, system: system, override: override)
            if theme.warnings.isEmpty {
                ok("\(FileManager.default.fileExists(atPath: files.userTheme.path) ? "theme.json" : "built-in theme") in \(theme.mode.rawValue) mode")
            }
            for warning in theme.warnings {
                fail("theme: \(warning)")
            }
        } catch {
            fail("theme: \(error)")
        }
    }
}

func doctorText() -> String {
    let onDisk = { Doctor.report(nil, system: Palette.Mode(NSApplication.shared.effectiveAppearance)) }
    do {
        switch try Response.decode(line: requestLine(Request.doctor.line, path: socketPath, timeout: 10)) {
        case let .ok(report): return report
        case let .failure(message): return "gary: \(message)"
        }
    } catch SocketError.unreachable {
        return onDisk()
    } catch {
        return "gary: \(error); reading the files on disk instead\n\n" + onDisk()
    }
}

func runDoctor() -> Int32 {
    print(doctorText())
    return 0
}
