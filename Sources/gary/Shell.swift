import AppKit
import GaryCore
import GarySocket

struct MountKey: Hashable {
    let slot: SlotKey
    let surface: String
    let display: String
}

final class Shell {
    let hub = StateHub(sources: Capability.topics)
    private let capabilities: CapabilityNames
    var theme: Theme
    var themePayload: JSON?
    var paletteFile: PaletteFile?
    var systemMode = Palette.Mode(NSApp.effectiveAppearance)
    private var appearanceObservation: NSKeyValueObservation?
    var config = ShellConfig.defaults
    private(set) var catalog = PluginCatalog()
    private(set) var resolution: ShellConfig.Resolution
    var slots: [SlotKey: PluginSlot] = [:]
    var displays: [DisplayInfo] = []
    var bars = PerDisplay<BarWindow>()
    var windows: [MountKey: SurfaceWindow] = [:]
    var barsAside: [String: Bool] = [:]
    var asideTimer: Timer?
    var mounts: [MountKey: TreeHostingView] = [:]
    let tooltipPanel: TooltipPanel
    var clickMonitors: [Any] = []
    private var hotkeys: HotkeyCenter?
    var previousApp: NSRunningApplication?
    private var server: LineServer?
    private var watcher: FileWatcher?
    private var watchedRoots: [URL] = []
    private var installingPackages: Set<PackageIdentity> = []
    private var signals: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []

    init() throws {
        capabilities = Capability.names()
        theme = try Theme.parse(JSON.parse(Data(contentsOf: Paths.defaultTheme)), palette: Palette(nil, system: systemMode))
        tooltipPanel = TooltipPanel(theme: theme)
        resolution = config.resolve(catalog)
    }

    func start() throws {
        hotkeys = HotkeyCenter { [weak self] binding in self?.hotkeyPressed(binding) }
        server = try LineServer(path: socketPath) { [weak self] line in self?.serve(line) ?? Response.failure("shutting down").line }
        SystemState.restore()
        try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.packages, withIntermediateDirectories: true)
        loadPalette()
        reloadTheme(Trace("start"))
        loadConfig()
        scan()
        resolve()
        refreshDisplays(Trace("start"))
        sync(Trace("start"))
        offerOnboarding(Trace("start"))
        reopenAfterRestart(Trace("start"))
        installMissingPackages()

        watch()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            let mode = Palette.Mode(app.effectiveAppearance)
            DispatchQueue.main.async { self?.systemAppearanceChanged(mode) }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDisplays(Trace("screens"))
            },
            center.addObserver(forName: .restartGary, object: nil, queue: .main) { [weak self] note in
                self?.restart(reopening: note.object as? PluginID)
            },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                SystemState.restore(SystemState.saved)
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
            "ready pid=\(getpid()) levels=bar:\(SurfaceLevels.bar),\(SurfaceLayer.allCases.map { "\($0.rawValue):\(SurfaceLevels.level($0))" }.joined(separator: ",")) plugins=\(catalog.sortedIDs.map(\.rawValue).joined(separator: ","))",
        )
    }

    func quit(_ status: Int32 = 0) {
        SystemState.restore(SystemState.saved)
        server?.stop()
        unlink(socketPath)
        exit(status)
    }

    private func restart(reopening id: PluginID?) {
        log("restart: asked by \(id?.rawValue ?? "unknown")")
        let shown = id.map { id in surfaceSlots(id).flatMap(\.shown.keys).compactMap { SurfaceAddress(id, surface: $0) } } ?? []
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
        [Paths.userPlugins, Paths.packages] + config.packages.compactMap {
            if case let .local(url) = $0 {
                url
            } else {
                nil
            }
        }
    }

    func watch() {
        let roots = [Paths.config] + pluginRoots
        guard roots != watchedRoots else { return }
        watchedRoots = roots
        watcher?.stop()
        watcher = FileWatcher(roots: roots) { [weak self] paths, trace in self?.filesChanged(paths, trace) }
    }

    func installMissingPackages() {
        for source in config.packages where source.managedPath != nil && !PackageStore.isInstalled(source) {
            guard installingPackages.insert(source.identity).inserted else { continue }
            log("package \(source.declaration): installing")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try PackageStore.install(source) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.installingPackages.remove(source.identity)
                    switch result {
                    case .success:
                        log("package \(source.declaration): installed \(PackageStore.revision(source) ?? "")")
                        _ = self.refresh(config: false, catalog: true, Trace("package"))
                    case let .failure(error):
                        log("package \(source.declaration): not installed, Gary tries again on the next start or gary plugin update: \(error)")
                    }
                }
            }
        }
    }

    func scan() {
        catalog = PluginCatalog.scan(
            builtin: Paths.builtinPlugins, user: Paths.userPlugins, packages: config.packages.map(PackageStore.directory), capabilities: capabilities,
        )
        for problem in catalog.problems {
            log("plugin \(problem.directory.path): \(problem.reason)")
        }
    }

    func resolve() {
        resolution = config.resolve(catalog)
        PermissionNeed.enabledPlugins = enabledManifests
        for warning in resolution.warnings {
            log("shell.json: \(warning)")
        }
        hotkeys?.update(resolution.enabled.sorted().compactMap { catalog.plugins[$0]?.manifest }.flatMap { manifest in
            manifest.hotkeys.map { HotkeyBinding(owner: manifest.id, hotkey: $0) }
        })
    }
}
