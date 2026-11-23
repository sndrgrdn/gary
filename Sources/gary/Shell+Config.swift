import AppKit
import GaryCore

extension Shell {
    func systemAppearanceChanged(_ mode: Palette.Mode) {
        guard theme.follow(mode) else { return }
        log("system appearance \(mode.rawValue)")
        changeTheme(Trace("appearance"), theme.reload)
    }

    @discardableResult
    func changeTheme(_ trace: Trace, _ update: () throws -> Bool) -> Response {
        let started = now()
        do {
            guard try update() else { return .ok("theme unchanged") }
            let applied = theme.value
            ToastStack.shared.theme = applied
            for warning in applied.warnings {
                log("theme \(warning)")
            }
            if let change = screens.restyle(builtinBar: usesBuiltinBar) {
                displaysChanged(change, trace)
            }
            screens.commitFrame()
            let json = applied.json
            for slot in slots.values {
                slot.candidate?.setTheme(json, trace)
                slot.runtime?.setTheme(json, trace)
            }
            let end = now()
            log(String(
                format: "theme applied mode=%@ palette=%@ cause=%@ since_ms=%.3f apply_ms=%.3f",
                applied.mode.rawValue,
                theme.palette == nil ? "built-in" : "palette.toml",
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

    func refresh(config reloadsConfig: Bool, catalog rescans: Bool, _ trace: Trace) -> Response {
        let refresh = setup.refresh(config: reloadsConfig, catalog: rescans)
        if refresh.packagesChanged {
            watch()
            installMissingPackages()
        }
        guard refresh.resolved else { return refresh.response }
        applyResolution()
        sync(trace, reloading: Set(slots.values.map(\.key).filter { refresh.settingsChanged.contains($0.id) }))
        offerOnboarding(trace)
        return refresh.response
    }

    private var missingPermissions: [String] {
        PermissionNeed.all(enabled: setup.enabledManifests, checkGrants: true).filter(\.isMissing).map(\.permission.rawValue)
    }

    func offerOnboarding(_ trace: Trace) {
        guard slots.surfaces(of: .onboarding).first?.visible == false else { return }
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
            theme.loadPalette()
        }
        if changes.contains(.theme) || changes.contains(.palette) {
            changeTheme(trace, theme.reload)
        }
        let configChanged = changes.contains(.shellConfig)
        if rescan || configChanged {
            _ = refresh(config: configChanged, catalog: rescan, trace)
        }
        for key in reloads {
            perform(slots.reload(key), trace)
        }
    }
}

private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}
