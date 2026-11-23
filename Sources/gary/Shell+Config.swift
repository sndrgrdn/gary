import AppKit
import GaryCore

extension Shell {
    func loadPalette() {
        do {
            paletteFile = try files.paletteFile()
            for problem in paletteFile?.ignored ?? [] {
                log("palette.toml \(problem); ignored")
            }
        } catch {
            log("palette.toml: \(error); using the built-in palette")
            paletteFile = nil
        }
    }

    func systemAppearanceChanged(_ mode: Palette.Mode) {
        guard mode != systemMode else { return }
        systemMode = mode
        log("system appearance \(mode.rawValue)")
        reloadTheme(Trace("appearance"))
    }

    @discardableResult
    func reloadTheme(_ trace: Trace) -> Response {
        let started = now()
        do {
            let next = try files.theme(palette: paletteFile, system: systemMode, override: themePayload)
            guard next != theme else { return .ok("theme unchanged") }
            theme = next
            tooltipPanel.theme = theme
            ToastStack.shared.theme = theme
            for warning in theme.warnings {
                log("theme \(warning)")
            }
            for panel in panels {
                panel.appearance = appearance
            }
            refreshDisplays(trace)
            for bar in bars.surfaces.values {
                bar.layout(theme: theme)
            }
            for (key, view) in mounts {
                view.tree.theme = theme(for: key.slot.kind)
            }
            for key in mounts.keys {
                place(key)
            }
            commitFrame()
            let json = theme.json
            for slot in slots.values {
                slot.candidate?.setTheme(json, trace)
                slot.runtime?.setTheme(json, trace)
            }
            let end = now()
            log(String(
                format: "theme applied mode=%@ palette=%@ cause=%@ since_ms=%.3f apply_ms=%.3f",
                theme.mode.rawValue,
                paletteFile == nil ? "built-in" : "palette.toml",
                trace.cause,
                (end - trace.start) * 1000,
                (end - started) * 1000,
            ))
            return .ok("theme applied")
        } catch {
            log("theme: \(error); keeping the current theme")
            return .failure("\(error)")
        }
    }

    @discardableResult
    func loadConfig() -> Response {
        do {
            guard let loaded = try files.config() else {
                config = .defaults
                return .ok("no shell.json; using defaults")
            }
            config = loaded
            for warning in config.warnings {
                log("\(warning); skipped")
            }
            return .ok("config loaded")
        } catch {
            log("\(error); keeping the current config")
            return .failure("\(error)")
        }
    }

    func refresh(config reloadsConfig: Bool, catalog rescans: Bool, _ trace: Trace) -> Response {
        let previous = config
        let response = reloadsConfig ? loadConfig() : .ok("config unchanged")
        let packagesChanged = config.packages != previous.packages
        if packagesChanged {
            watch()
            installMissingPackages()
        }
        if rescans || packagesChanged {
            scan()
        }
        guard rescans || config != previous else { return response }
        resolve()
        for slot in slots.values where config.settings[slot.key.id] != previous.settings[slot.key.id] {
            reload(slot, trace)
        }
        sync(trace)
        offerOnboarding(trace)
        return response
    }

    private var missingPermissions: [String] {
        PermissionNeed.all(enabled: enabledManifests, checkGrants: true).filter(\.isMissing).map(\.permission.rawValue)
    }

    func offerOnboarding(_ trace: Trace) {
        guard surfaceSlots(.onboarding).first?.visible == false else { return }
        guard LocationAccess.shared.reported else {
            LocationAccess.shared.whenReported { [weak self] in self?.offerOnboarding(trace) }
            return
        }
        let missing = missingPermissions
        let dismissed = (try? JSON.parse(Data(contentsOf: Paths.onboarding)))?["missing"]?.array?.compactMap(\.string)
        if let dismissed, Set(missing).isSubset(of: dismissed) {
            return
        }
        log("onboarding: shown, " + (dismissed == nil ? "first launch" : "missing \(missing.joined(separator: ", "))"))
        summon(SurfaceAddress(.onboarding), trace)
    }

    func recordOnboardingDismissed() {
        do {
            try FileManager.default.createDirectory(at: Paths.onboarding.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(JSON.object(["missing": .array(missingPermissions.map(JSON.string))]).text.utf8).write(to: Paths.onboarding, options: .atomic)
        } catch {
            log("onboarding: not recorded: \(error)")
        }
    }

    func filesChanged(_ paths: Set<String>, _ trace: Trace) {
        let configRoot = realPath(Paths.config)
        let roots = pluginRoots.map(realPath)
        let changes = paths.compactMap { ConfigFileChange(path: $0, configRoot: configRoot, pluginRoots: roots) }
        var rescan = false
        var reloads = Set<SlotKey>()
        for case let .plugin(path, rescansCatalog) in changes {
            let owners = slots.values.filter { $0.bundle.origin == .user && path.hasPrefix(realPath($0.bundle.directory) + "/") }
            if owners.isEmpty || rescansCatalog {
                rescan = true
            } else {
                reloads.formUnion(owners.map(\.key))
            }
        }
        if changes.contains(.palette) {
            loadPalette()
        }
        if changes.contains(.theme) || changes.contains(.palette) {
            reloadTheme(trace)
        }
        let configChanged = changes.contains(.shellConfig)
        if rescan || configChanged {
            _ = refresh(config: configChanged, catalog: rescan, trace)
        }
        for key in reloads {
            guard let slot = slots[key] else { continue }
            reload(slot, trace)
        }
    }
}

private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}
