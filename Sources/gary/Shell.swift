import AppKit
import GaryCore
import GarySocket

final class Shell {
    let hub = StateHub(sources: Capability.topics)
    let engines = PluginEngines()
    let theme: CurrentTheme
    let setup = PluginSetup(files: ConfigFiles())
    private(set) lazy var slots = PluginSlots<PluginRuntime>(
        make: { self.makeRuntime($0, $1, $2) },
        scene: { self.scene($0, $1) },
    )
    private(set) lazy var screens = Screens(theme: theme, setup: setup, slots: slots) { [weak self] key, trace in
        _ = self?.hide(key.surface, in: key.slot, trace)
    }

    private(set) var hotkeys: HotkeyCenter?
    var mediaKeys: MediaKeyTap?
    private var server: LineServer?
    private var watcher: FileWatcher?
    private var installingPackages: Set<PackageIdentity> = []
    private var signals: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    init() throws {
        theme = try CurrentTheme(files: ConfigFiles(), system: Palette.Mode(NSApp.effectiveAppearance))
        ToastStack.shared.theme = theme.value
    }

    func start() throws {
        hotkeys = HotkeyCenter { [weak self] binding in self?.hotkeyPressed(binding) }
        HotkeyListeners.shared.changed = { [weak self] in self?.updateHotkeys() }
        mediaKeys = MediaKeyTap { [weak self] event, keys in self?.mediaKeyPressed(event, keys) }
        server = try LineServer(path: socketPath) { [weak self] line in self?.serve(line) ?? Response.failure("shutting down").line }
        SystemState.restore()
        try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.packages, withIntermediateDirectories: true)
        theme.loadPalette()
        changeTheme(Trace("start"), theme.reload)
        _ = setup.refresh(config: true, catalog: true)
        applyResolution()
        refreshDisplays(Trace("start"))
        sync(Trace("start"))
        offerOnboarding(Trace("start"))
        reopenAfterRestart(Trace("start"))
        installMissingPackages()

        watch()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.systemAppearanceChanged(Palette.Mode(NSApp.effectiveAppearance)) }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplays(Trace("screens")) }
            },
            center.addObserver(forName: .restartGary, object: nil, queue: .main) { [weak self] note in
                let plugin = note.object as? PluginID
                MainActor.assumeIsolated { self?.restart(reopening: plugin) }
            },
            center.addObserver(forName: .showAppDragTile, object: nil, queue: .main) { [weak self] note in
                guard let permission = note.object as? Permission else { return }
                MainActor.assumeIsolated { self?.showAppDragTile(until: permission) }
            },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SystemState.restore(SystemState.saved) }
            },
        ]
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signals.append(source)
        }
        log(PrivateSymbolCheck.summary())
        log(
            "ready pid=\(getpid()) levels=bar:\(SurfaceLevels.bar),\(SurfaceLayer.allCases.map { "\($0.rawValue):\(SurfaceLevels.level($0))" }.joined(separator: ",")) plugins=\(setup.catalog.sortedIDs.map(\.rawValue).joined(separator: ","))",
        )
    }

    func quit(_ status: Int32 = 0) {
        SystemState.restore(SystemState.saved)
        server?.stop()
        unlink(socketPath)
        exit(status)
    }

    private func showAppDragTile(until permission: Permission) {
        AppDragTile.show(until: permission, theme: theme.value)
    }

    private func restart(reopening id: PluginID?) {
        log("restart: asked by \(id?.rawValue ?? "unknown")")
        let shown = id.map { id in slots.surfaces(of: id).flatMap(\.shown.keys).compactMap { SurfaceAddress(id, surface: $0) } } ?? []
        if !shown.isEmpty {
            try? Data(JSON.array(shown.map { .string($0.description) }).text.utf8).write(to: Paths.reopen, options: .atomic)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.quit(ProcessExit.restart) }
    }

    private func reopenAfterRestart(_ trace: Trace) {
        guard let data = try? Data(contentsOf: Paths.reopen) else { return }
        try? FileManager.default.removeItem(at: Paths.reopen)
        for address in (try? JSON.parse(data))?.array?.compactMap({ $0.string.flatMap(SurfaceAddress.init) }) ?? [] {
            summon(address, trace)
        }
    }

    var pluginRoots: [URL] {
        [Paths.userPlugins, Paths.packages] + setup.config.packages.compactMap {
            if case let .local(url) = $0 {
                url
            } else {
                nil
            }
        }
    }

    func watch() {
        let roots = [Paths.config] + pluginRoots
        guard roots != watcher?.roots else { return }
        watcher?.stop()
        watcher = FileWatcher(roots: roots) { [weak self] paths, trace in self?.filesChanged(paths, trace) }
    }

    func installMissingPackages() {
        for source in setup.config.packages where source.managedPath != nil && !PackageStore.isInstalled(source) {
            guard installingPackages.insert(source.identity).inserted else { continue }
            log("package \(source.declaration): installing")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try PackageStore.install(source) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    installingPackages.remove(source.identity)
                    switch result {
                    case .success:
                        log("package \(source.declaration): installed \(PackageStore.revision(source) ?? "")")
                        _ = refresh(config: false, catalog: true, Trace("package"))
                    case let .failure(error):
                        log("package \(source.declaration): not installed, Gary tries again on the next start or gary plugin update: \(error)")
                    }
                }
            }
        }
    }

    func applyResolution() {
        PermissionNeed.enabledPlugins = setup.enabledManifests
        updateHotkeys()
    }

    private func updateHotkeys() {
        hotkeys?.update(setup.resolution.enabled.sorted().compactMap { setup.catalog.plugins[$0]?.manifest }.flatMap { manifest in
            manifest.hotkeys.map { HotkeyBinding(owner: manifest.id, hotkey: $0) }
        } + HotkeyListeners.shared.bindings)
    }
}
