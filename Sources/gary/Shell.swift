import AppKit
import GaryCore
import GarySocket

enum Paths {
    static let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gary")
    static let userPlugins = config.appending(path: "plugins")
    static let shellConfig = config.appending(path: "shell.json")
    static let userTheme = config.appending(path: "theme.json")
    static let palette = config.appending(path: "palette.toml")
    static let builtinPlugins = Bundle.main.resourceURL!.appending(path: "plugins")
    static let examples = Bundle.main.resourceURL!.appending(path: "examples")
    static let defaultTheme = Bundle.main.resourceURL!.appending(path: "theme.json")
    static let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Gary/storage")
    static let systemRestore = storage.deletingLastPathComponent().appending(path: "restore.json")
    static let onboarding = storage.deletingLastPathComponent().appending(path: "onboarding.json")
    static let reopen = storage.deletingLastPathComponent().appending(path: "reopen.json")
}

struct SlotKey: Hashable, CustomStringConvertible {
    let id: PluginID
    let kind: PluginKind
    var description: String { "\(id)/\(kind.rawValue)" }
}

final class PluginSlot {
    enum Phase {
        case stopped
        case running(PluginRuntime)
        case failed(String)
        case disabled(String)
    }

    let key: SlotKey
    var bundle: PluginBundle
    var phase = Phase.stopped
    var failures = RestartBudget(limit: 5, window: 60)
    var candidate: PluginRuntime?
    var visible = false
    var focused: String?
    var surface: SurfaceSpec?
    var waiters: [(Response) -> Void] = []

    init(key: SlotKey, bundle: PluginBundle) {
        self.key = key
        self.bundle = bundle
    }

    var runtime: PluginRuntime? {
        if case .running(let runtime) = phase { return runtime }
        return nil
    }

    var disabledReason: String? {
        if case .disabled(let reason) = phase { return reason }
        return nil
    }

    func answerWaiters(_ response: Response) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter(response) }
    }
}

private struct MountKey: Hashable {
    let slot: SlotKey
    let display: String
}

final class Shell {
    private let hub = StateHub(sources: Capability.topics)
    private let capabilities: CapabilityNames
    private let levels = SurfaceLevels.forSystem(ProcessInfo.processInfo.operatingSystemVersion)
    private var theme: Theme
    private var themePayload: JSON?
    private var paletteFile: PaletteFile?
    private var systemMode = Palette.Mode(NSApp.effectiveAppearance)
    private var appearanceObservation: NSKeyValueObservation?
    private var config = ShellConfig.defaults
    private var catalog = PluginCatalog()
    private var resolution: ShellConfig.Resolution
    private var slots: [SlotKey: PluginSlot] = [:]
    private var displays: [DisplayInfo] = []
    private var bars = PerDisplay<BarWindow>()
    private var windows: [MountKey: SurfaceWindow] = [:]
    private var barsAside: [String: Bool] = [:]
    private var asideTimer: Timer?
    private var mounts: [MountKey: TreeHostingView] = [:]
    private var clickMonitors: [Any] = []
    private var hotkeys: HotkeyCenter?
    private var previousApp: NSRunningApplication?
    private var server: LineServer?
    private var watcher: FileWatcher?
    private var signals: [DispatchSourceSignal] = []

    init() throws {
        capabilities = try Capability.names()
        theme = try Theme.parse(try JSON.parse(Data(contentsOf: Paths.defaultTheme)), palette: Palette(nil, system: systemMode))
        resolution = config.resolve(catalog)
    }

    func start() throws {
        hotkeys = HotkeyCenter { [weak self] binding in self?.hotkeyPressed(binding) }
        server = try LineServer(path: socketPath) { [weak self] line in self?.serve(line) ?? Response.failure("shutting down").line }
        SystemState.restore()
        try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
        loadPalette()
        reloadTheme(Trace("start"))
        loadConfig()
        scan()
        resolve()
        refreshDisplays(Trace("start"))
        sync(Trace("start"))
        offerOnboarding(Trace("start"))
        reopenAfterRestart(Trace("start"))

        watcher = FileWatcher(root: Paths.config) { [weak self] paths, trace in self?.filesChanged(paths, trace) }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            let mode = Palette.Mode(app.effectiveAppearance)
            DispatchQueue.main.async { self?.systemAppearanceChanged(mode) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays(Trace("screens"))
        }
        NotificationCenter.default.addObserver(forName: .restartGary, object: nil, queue: .main) { [weak self] note in
            self?.restart(reopening: note.object as? PluginID)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            SystemState.restore(SystemState.saved)
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signals.append(source)
        }
        log(PrivateSymbolCheck.summary())
        log("ready pid=\(getpid()) levels=bar:\(levels.bar),\(SurfaceLayer.allCases.map { "\($0.rawValue):\(levels.level($0))" }.joined(separator: ",")) plugins=\(catalog.sortedIDs.map(\.rawValue).joined(separator: ","))")
    }

    private func quit(_ status: Int32 = 0) {
        SystemState.restore(SystemState.saved)
        server?.stop()
        unlink(socketPath)
        exit(status)
    }

    private func restart(reopening id: PluginID?) {
        log("restart: asked by \(id?.rawValue ?? "unknown")")
        if let id, surfaceSlot(id)?.visible == true {
            try? Data(JSON.array([.string(id.rawValue)]).text.utf8).write(to: Paths.reopen, options: .atomic)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.quit(ProcessExit.restart) }
    }

    private func reopenAfterRestart(_ trace: Trace) {
        guard let data = try? Data(contentsOf: Paths.reopen) else { return }
        try? FileManager.default.removeItem(at: Paths.reopen)
        for id in (try? JSON.parse(data))?.array?.compactMap({ $0.string.flatMap(PluginID.init) }) ?? [] {
            summon(id, trace) { _ in }
        }
    }

    private func scan() {
        catalog = PluginCatalog.scan(builtin: Paths.builtinPlugins, user: Paths.userPlugins, capabilities: capabilities)
        for problem in catalog.problems { log("plugin \(problem.directory.path): \(problem.reason)") }
    }

    private func resolve() {
        resolution = config.resolve(catalog)
        PermissionNeed.enabledPlugins = enabledManifests
        for warning in resolution.warnings { log("shell.json: \(warning)") }
        hotkeys?.update(resolution.enabled.sorted().flatMap { id in
            catalog.plugins[id]!.manifest.hotkeys.map { HotkeyBinding(owner: id, hotkey: $0) }
        })
    }

    private func hotkeyPressed(_ binding: HotkeyBinding) {
        let trace = Trace("hotkey")
        if tracing { log("hotkey \(binding.hotkey.keys) plugin=\(binding.owner) id=\(binding.hotkey.id)") }
        guard let slot = handlerSlot(binding.owner) else { return }
        withRuntime(slot, trace) { runtime in runtime?.hotkey(binding.hotkey.id) }
    }

    private func handlerSlot(_ id: PluginID) -> PluginSlot? {
        let order: [PluginKind] = [.service, .panel, .overlay, .menu, .bar, .barWidget]
        return order.lazy.compactMap { self.slots[SlotKey(id: id, kind: $0)] }.first
    }

    private func withRuntime(_ slot: PluginSlot, _ trace: Trace, _ body: @escaping (PluginRuntime?) -> Void) {
        if let runtime = slot.runtime { return body(runtime) }
        if slot.disabledReason != nil { return body(nil) }
        slot.waiters.append { [weak slot] _ in body(slot?.runtime) }
        if slot.candidate == nil { load(slot, trace) }
    }

    private var usesBuiltinBar: Bool {
        guard let id = resolution.barPlugin else { return true }
        switch slots[SlotKey(id: id, kind: .bar)]?.phase {
        case .failed?, .disabled?: return true
        default: return false
        }
    }

    private func sync(_ trace: Trace) {
        refreshDisplays(trace)
        var wanted: [SlotKey: PluginBundle] = [:]
        if usesBuiltinBar {
            for id in resolution.bar.values.joined() { wanted[SlotKey(id: id, kind: .barWidget)] = catalog.plugins[id] }
        }
        if let id = resolution.barPlugin { wanted[SlotKey(id: id, kind: .bar)] = catalog.plugins[id] }
        for id in resolution.enabled {
            for kind in catalog.plugins[id]!.manifest.kinds where kind.isSurface || kind == .service {
                wanted[SlotKey(id: id, kind: kind)] = catalog.plugins[id]
            }
        }
        for (key, slot) in slots where wanted[key] == nil {
            stop(slot)
            slots[key] = nil
        }
        for (key, bundle) in wanted {
            if let slot = slots[key] {
                guard slot.bundle != bundle else { continue }
                slot.bundle = bundle
                reload(slot, trace)
            } else {
                let slot = PluginSlot(key: key, bundle: bundle)
                slots[key] = slot
                if !key.kind.isSurface { load(slot, trace) }
            }
        }
        arrangeBars()
        commitFrame()
    }

    private func reload(_ slot: PluginSlot, _ trace: Trace) {
        slot.failures.reset()
        if slot.disabledReason != nil { slot.phase = .stopped }
        if isLive(slot) { load(slot, trace) }
    }

    private func isLive(_ slot: PluginSlot) -> Bool {
        !slot.key.kind.isSurface || slot.visible || slot.runtime != nil
    }

    private func scene(for slot: PluginSlot) -> Scene {
        switch slot.key.kind {
        case .barWidget: return Scene(displays: displays.filter { bars[$0.id] != nil }, shown: true)
        case .bar: return Scene(displays: displays, shown: true)
        case .service: return Scene()
        case .panel, .overlay, .menu: return Scene(displays: displays, shown: slot.visible, focused: slot.focused)
        }
    }

    private func load(_ slot: PluginSlot, _ trace: Trace) {
        slot.candidate?.stop()
        let key = slot.key
        let runtime = PluginRuntime(
            bundle: slot.bundle, kind: key.kind, scene: scene(for: slot),
            settings: config.settings[key.id] ?? .object([:]), theme: theme.json, hub: hub
        ) { [weak self] runtime, event in
            DispatchQueue.main.async { self?.handle(event, from: runtime, key) }
        }
        slot.candidate = runtime
        runtime.load(trace)
    }

    private func stop(_ slot: PluginSlot) {
        slot.candidate?.stop()
        slot.candidate = nil
        slot.runtime?.stop()
        slot.phase = .stopped
        unmount(slot.key)
        slot.answerWaiters(.failure("\(slot.key.id) was stopped"))
    }

    private func handle(_ event: RuntimeEvent, from runtime: PluginRuntime, _ key: SlotKey) {
        guard let slot = slots[key], slot.candidate === runtime || slot.runtime === runtime else {
            runtime.stop()
            return
        }
        switch event {
        case .loaded(let output, let trace):
            slot.candidate = nil
            slot.runtime?.stop()
            slot.phase = .running(runtime)
            log("plugin \(key): loaded \(slot.bundle.manifest.version)")
            present(slot, output, trace)
            if runtime.initialScene != scene(for: slot) { runtime.setScene(scene(for: slot), trace) }
            slot.answerWaiters(.ok(slot.visible ? "shown" : "loaded"))
            if key.kind == .bar { sync(trace) }
        case .output(let output, let trace):
            guard slot.runtime === runtime else { return }
            present(slot, output, trace)
            if slot.visible { slot.answerWaiters(.ok("shown")) }
        case .surface(let request):
            let trace = Trace("host-\(request.rawValue)")
            switch request {
            case .show: summon(key.id, trace) { _ in }
            case .hide: _ = hide(key.id, trace)
            case .toggle: toggle(key.id, trace) { _ in }
            }
        case .call(let method, let arguments, let reply):
            call(key.id, method, arguments, Trace("host-call"), reply)
        case .failed(let reason):
            if slot.candidate === runtime {
                slot.candidate = nil
                if slot.runtime != nil {
                    log("plugin \(key): reload rejected, the running version stays: \(reason)")
                    return
                }
            }
            slot.phase = .failed(reason)
            unmount(key)
            slot.visible = false
            slot.answerWaiters(.failure("\(key.id) failed: \(reason)"))
            log("plugin \(key): failed: \(reason)")
            if !slot.failures.allowsRestart(afterFailureAt: now()) {
                slot.phase = .disabled("\(slot.failures.summary), last: \(reason)")
                log("plugin \(key): disabled after \(slot.failures.summary); reload it or change its files to try again")
            } else if !key.kind.isSurface {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak slot] in
                    guard let self, let slot, slots[key] === slot, case .failed = slot.phase, slot.candidate == nil else { return }
                    log("plugin \(key): restarting (\(slot.failures.summary))")
                    load(slot, Trace("restart"))
                }
            }
            if key.kind == .bar { sync(Trace("bar-fallback")) }
            commitFrame()
        }
    }

    private func perform(_ action: String, _ payload: JSON, _ key: SlotKey) {
        if tracing { log("action plugin=\(key) action=\(action) payload=\(payload.text)") }
        slots[key]?.runtime?.perform(action, payload)
    }


    private func present(_ slot: PluginSlot, _ output: RuntimeOutput, _ trace: Trace) {
        if slot.key.kind.isSurface && !slot.visible { return }
        slot.surface = output.surface
        for (display, tree) in output.trees { mount(slot, display, tree, trace) }
        for key in mounts.keys where key.slot == slot.key && output.trees[key.display] == nil { unmount(key) }
        commitFrame()
    }

    private func mount(_ slot: PluginSlot, _ display: String, _ tree: Node, _ trace: Trace) {
        let key = MountKey(slot: slot.key, display: display)
        let slotKey = slot.key
        let onAction: ActionHandler = { [weak self] action, payload in self?.perform(action, payload, slotKey) }
        let started = now()
        let changed: Bool
        if let view = mounts[key] {
            changed = view.tree.root != tree
            if changed { view.tree.root = tree }
        } else {
            mounts[key] = TreeHostingView(tree: MountedTree(root: tree, theme: theme(for: slot.key.kind)), onAction: onAction)
            changed = true
        }
        place(key)
        if tracing {
            let end = now()
            log(String(format: "commit plugin=%@ display=%@ cause=%@ since_ms=%.3f apply_ms=%.3f changed=%d tree=%@",
                       slot.key.id.rawValue, display, trace.cause, (end - trace.start) * 1000, (end - started) * 1000, changed ? 1 : 0, tree.summary))
        }
    }

    private func theme(for kind: PluginKind) -> Theme {
        kind == .bar || kind == .barWidget ? theme.inBar : theme
    }

    private func place(_ key: MountKey) {
        guard let view = mounts[key], let slot = slots[key.slot] else { return }
        if key.slot.kind == .barWidget {
            guard let bar = bars[key.display] else { return }
            for (section, ids) in resolution.bar where ids.contains(key.slot.id) {
                bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), display: key.display)] })
            }
            return
        }
        guard let display = displays.first(where: { $0.id == key.display }) else { return }
        let window = windows[key] ?? SurfaceWindow()
        let isNew = windows[key] == nil
        windows[key] = window
        if isNew { window.panel.appearance = appearance }
        window.setContent(view)
        if key.slot.kind == .bar {
            var spec = SurfaceSpec.defaults(for: .bar)
            spec.anchors = Edges(top: true, bottom: false, left: true, right: true)
            spec.height = .points(display.band)
            spec.exclusionMode = .ignore
            window.place(spec, on: display, level: barLevel(display.id), theme: theme)
        } else if let spec = slot.surface {
            window.place(spec, on: display, level: levels.level(spec.layer), theme: theme)
        }
        if isNew {
            if key.slot.kind == .bar { watchTopEdge(of: window.panel.contentView!) { [weak self] in self?.pointerReachedTop(key.display) } }
            window.show(fade: fade(key.slot))
            if key.slot.kind.isSurface, slot.surface?.focusable == true { focus(window, key.slot) }
            watchClicks()
        }
    }

    private func focus(_ window: SurfaceWindow, _ slot: SlotKey) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() { previousApp = front }
        window.panel.onKey = { [weak self] key in self?.keyPressed(key, slot) }
        if slot.kind == .menu { window.panel.onResignKey = { [weak self] in _ = self?.hide(slot.id, Trace("resign-key")) } }
        window.focus()
    }

    private func keyPressed(_ key: String, _ slot: SlotKey) {
        if tracing { log("key plugin=\(slot) key=\(key)") }
        slots[slot]?.runtime?.key(key)
        if slot.kind == .menu && key == "escape" { _ = hide(slot.id, Trace("escape")) }
    }

    private func unmount(_ key: MountKey) {
        if let window = windows.removeValue(forKey: key) {
            let hadFocus = window.panel.isKeyWindow
            window.close(fade: fade(key.slot))
            mounts[key] = nil
            if hadFocus { returnFocus() }
        } else {
            mounts.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    private func returnFocus() {
        guard !windows.values.contains(where: { $0.panel.isKeyWindow }) else { return }
        NSApp.deactivate()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { previousApp?.activate() }
        previousApp = nil
        if tracing {
            DispatchQueue.main.async {
                log("focus returned active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
            }
        }
    }

    private func fade(_ slot: SlotKey) -> Double { slot.kind.isSurface ? theme.motion.fade : 0 }

    private func watchClicks() {
        let open = windows.keys.contains { $0.slot.kind == .menu }
        guard open == clickMonitors.isEmpty else { return }
        if !open {
            for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
            clickMonitors = []
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.clicked(at: NSEvent.mouseLocation) } as Any,
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.clicked(at: NSEvent.mouseLocation)
                return event
            } as Any,
        ]
    }

    private func clicked(at point: NSPoint) {
        let menus = Set(windows.keys.filter { $0.slot.kind == .menu }.map(\.slot))
        for menu in menus where !windows.contains(where: { $0.key.slot == menu && $0.value.contains(point) }) {
            _ = hide(menu.id, Trace("click-outside"))
        }
    }

    private func unmount(_ slot: SlotKey) {
        for key in mounts.keys where key.slot == slot { unmount(key) }
        if slot.kind == .barWidget { arrangeBars() }
        watchClicks()
    }

    private func arrangeBars() {
        for bar in bars.surfaces.values {
            for (section, ids) in resolution.bar {
                bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), display: bar.display.id)] })
            }
        }
    }

    private func barLevel(_ display: String) -> Int {
        barsAside[display] == nil ? levels.bar : levels.barAside
    }

    private func applyBarLevel(_ display: String) {
        let aside = barsAside[display] != nil
        let panels = [bars[display]?.panel].compactMap { $0 } + windows.filter { $0.key.slot.kind == .bar && $0.key.display == display }.map(\.value.panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = theme.motion.fade
            for panel in panels {
                panel.level = NSWindow.Level(rawValue: barLevel(display))
                panel.animator().alphaValue = aside ? 0 : 1
            }
        }
    }

    private func pointerReachedTop(_ id: String) {
        guard config.revealMenuBar, !SystemState.saved.menuBarHidden, barsAside[id] == nil, let display = displays.first(where: { $0.id == id }) else { return }
        barsAside[id] = NativeMenuBar.revealed(on: display.frame)
        applyBarLevel(id)
        log("bar on \(id.prefix(8)) hides so the macOS menu bar can reveal")
        guard asideTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.returnBarsAside() }
        RunLoop.main.add(timer, forMode: .common)
        asideTimer = timer
    }

    private func returnBarsAside() {
        let pointer = NSEvent.mouseLocation
        for (id, menuBarWasShown) in barsAside {
            if let display = displays.first(where: { $0.id == id }), config.revealMenuBar, !SystemState.saved.menuBarHidden {
                let band = NSRect(x: display.frame.minX, y: display.frame.maxY - display.band, width: display.frame.width, height: display.band)
                if NSMouseInRect(pointer, band, false) || (!menuBarWasShown && NativeMenuBar.revealed(on: display.frame)) { continue }
            }
            barsAside[id] = nil
            applyBarLevel(id)
            log("bar on \(id.prefix(8)) returns over the macOS menu bar")
        }
        if barsAside.isEmpty {
            asideTimer?.invalidate()
            asideTimer = nil
        }
    }

    private var panels: [NSPanel] { bars.surfaces.values.map(\.panel) + windows.values.map(\.panel) }

    private var appearance: NSAppearance? { NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua) }

    private func commitFrame() {
        for panel in panels where panel.isVisible {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        CATransaction.flush()
    }


    private func refreshDisplays(_ trace: Trace) {
        let next = NSScreen.screens.enumerated().map { $1.display(index: $0, theme: theme) }
        let change = DisplayChange(from: displays, to: next)
        displays = next
        let theme = theme, appearance = appearance, level = levels.bar
        let barChange = bars.sync(usesBuiltinBar ? next : [], open: { [weak self] display in
            let bar = BarWindow(display: display, level: level)
            watchTopEdge(of: bar.panel.contentView!) { [weak self, weak bar] in
                if let bar { self?.pointerReachedTop(bar.display.id) }
            }
            bar.panel.appearance = appearance
            bar.layout(theme: theme)
            return bar
        }, update: { bar, display in
            bar.display = display
            bar.layout(theme: theme)
        }, close: { $0.close() })
        guard !change.isEmpty || !barChange.isEmpty else { return }
        for key in mounts.keys where change.removed.contains(key.display) || (key.slot.kind == .barWidget && bars[key.display] == nil) {
            unmount(key)
        }
        for slot in slots.values { slot.runtime?.setScene(scene(for: slot), trace) }
        log("screens added=\(change.added.count) removed=\(change.removed.count) changed=\(change.changed.count) bars=\(bars.surfaces.count): "
            + displays.map { "\($0.id.prefix(8)) \(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY)) notch=\($0.notch != nil)" }.joined(separator: "; "))
    }

    private func loadPalette() {
        guard FileManager.default.fileExists(atPath: Paths.palette.path) else {
            paletteFile = nil
            return
        }
        do {
            let file = PaletteFile.parse(try String(contentsOf: Paths.palette, encoding: .utf8))
            for problem in file.ignored { log("palette.toml \(problem); ignored") }
            paletteFile = file
        } catch {
            log("palette.toml: \(error); using the built-in palette")
            paletteFile = nil
        }
    }

    private func systemAppearanceChanged(_ mode: Palette.Mode) {
        guard mode != systemMode else { return }
        systemMode = mode
        log("system appearance \(mode.rawValue)")
        reloadTheme(Trace("appearance"))
    }

    @discardableResult
    private func reloadTheme(_ trace: Trace) -> Response {
        let started = now()
        do {
            var override = themePayload ?? .object([:])
            if FileManager.default.fileExists(atPath: Paths.userTheme.path) {
                override = override.merging(try JSON.parse(Data(contentsOf: Paths.userTheme)))
            }
            let next = try Theme.parse(
                try JSON.parse(Data(contentsOf: Paths.defaultTheme)), override: override, palette: Palette(paletteFile, system: systemMode)
            )
            guard next != theme else { return .ok("theme unchanged") }
            theme = next
            AppDragTile.theme = theme
            for warning in theme.warnings { log("theme \(warning)") }
            for panel in panels { panel.appearance = appearance }
            refreshDisplays(trace)
            for bar in bars.surfaces.values { bar.layout(theme: theme) }
            for (key, view) in mounts { view.tree.theme = theme(for: key.slot.kind) }
            for key in mounts.keys { place(key) }
            commitFrame()
            let json = theme.json
            for slot in slots.values {
                slot.candidate?.setTheme(json, trace)
                slot.runtime?.setTheme(json, trace)
            }
            let end = now()
            log(String(format: "theme applied mode=%@ palette=%@ cause=%@ since_ms=%.3f apply_ms=%.3f", theme.mode.rawValue,
                       paletteFile == nil ? "built-in" : "palette.toml", trace.cause, (end - trace.start) * 1000, (end - started) * 1000))
            return .ok("theme applied")
        } catch {
            log("theme: \(error); keeping the current theme")
            return .failure("\(error)")
        }
    }


    @discardableResult
    private func loadConfig() -> Response {
        guard FileManager.default.fileExists(atPath: Paths.shellConfig.path) else {
            config = .defaults
            return .ok("no shell.json; using defaults")
        }
        do {
            config = try ShellConfig.parse(try JSON.parse(Data(contentsOf: Paths.shellConfig)))
            return .ok("config loaded")
        } catch {
            log("\(error); keeping the current config")
            return .failure("\(error)")
        }
    }

    private func refresh(config reloadsConfig: Bool, catalog rescans: Bool, _ trace: Trace) -> Response {
        let previous = config
        let response = reloadsConfig ? loadConfig() : .ok("config unchanged")
        if rescans { scan() }
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

    private func offerOnboarding(_ trace: Trace) {
        guard surfaceSlot(.onboarding)?.visible == false else { return }
        let missing = missingPermissions
        let dismissed = (try? JSON.parse(Data(contentsOf: Paths.onboarding)))?["missing"]?.array?.compactMap(\.string)
        if let dismissed, Set(missing).isSubset(of: dismissed) { return }
        log("onboarding: shown, " + (dismissed == nil ? "first launch" : "missing \(missing.joined(separator: ", "))"))
        summon(.onboarding, trace) { _ in }
    }

    private func recordOnboardingDismissed() {
        do {
            try FileManager.default.createDirectory(at: Paths.onboarding.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(JSON.object(["missing": .array(missingPermissions.map(JSON.string))]).text.utf8).write(to: Paths.onboarding, options: .atomic)
        } catch {
            log("onboarding: not recorded: \(error)")
        }
    }

    private func filesChanged(_ paths: Set<String>, _ trace: Trace) {
        let root = Paths.config.resolvingSymlinksInPath().path
        let plugins = Paths.userPlugins.resolvingSymlinksInPath().path + "/"
        var rescan = false, themeChanged = false, configChanged = false
        var reloads = Set<SlotKey>()
        for path in paths {
            if path == root + "/theme.json" {
                themeChanged = true
            } else if path == root + "/palette.toml" {
                loadPalette()
                themeChanged = true
            } else if path == root + "/shell.json" {
                configChanged = true
            } else if path.hasPrefix(plugins) {
                let relative = path.dropFirst(plugins.count)
                if relative.split(separator: "/").dropFirst().contains(where: { $0.hasPrefix(".") }) { continue }
                let directory = String(relative.prefix { $0 != "/" })
                let owners = slots.values.filter { $0.bundle.origin == .user && $0.bundle.directory.lastPathComponent == directory }
                if owners.isEmpty || relative.hasSuffix("/manifest.json") || !relative.contains("/") {
                    rescan = true
                } else {
                    reloads.formUnion(owners.map(\.key))
                }
            }
        }
        if themeChanged { reloadTheme(trace) }
        if rescan || configChanged { _ = refresh(config: configChanged, catalog: rescan, trace) }
        for key in reloads {
            guard let slot = slots[key] else { continue }
            reload(slot, trace)
        }
    }


    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var response: Response?

        func set(_ value: Response) {
            lock.withLock { if response == nil { response = value } }
            semaphore.signal()
        }

        func wait(_ timeout: TimeInterval) -> Response {
            _ = semaphore.wait(timeout: .now() + timeout)
            return lock.withLock { response ?? .failure("timed out") }
        }
    }

    private func serve(_ line: String) -> String {
        let request: Request
        do {
            request = try Request.decode(line: line)
        } catch {
            return Response.failure("\(error)").line
        }
        let box = ReplyBox()
        DispatchQueue.main.async { self.handle(request, reply: box.set) }
        return box.wait(request.timeout).line
    }

    private func handle(_ request: Request, reply: @escaping (Response) -> Void) {
        let trace = Trace("ipc-\(request.verb)")
        switch request {
        case .ping:
            reply(.ok("pong"))
        case .quit:
            reply(.ok("quitting"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.quit() }
        case .summon(let id):
            summon(id, trace, reply)
        case .hide(let id):
            reply(hide(id, trace))
        case .toggle(let id):
            toggle(id, trace, reply)
        case .reloadPlugins(let id):
            let live = slots.values.filter { (id == nil || $0.key.id == id) && (isLive($0) || $0.disabledReason != nil) }
            guard id == nil || !live.isEmpty else { return reply(.failure("\(id!) is not loaded")) }
            for slot in live { reload(slot, trace) }
            reply(.ok("reloading \(live.count)"))
        case .rescanPlugins:
            _ = refresh(config: false, catalog: true, trace)
            reply(.ok("\(catalog.plugins.count) plugins, \(catalog.problems.count) problems"))
        case .reloadConfig:
            reply(refresh(config: true, catalog: false, trace))
        case .applyTheme(let payload):
            themePayload = payload
            reply(reloadTheme(trace))
        case .listPlugins:
            reply(.ok(listing()))
        case .doctor:
            reply(.ok(Doctor.report(doctorRuntime())))
        case .permissions:
            reply(.ok(permissionReport(enabled: enabledManifests)))
        case .requestPermission(let permission):
            reply(.ok(permission.request()))
        case .action(let id, let kind, let action, let payload):
            guard let runtime = slots[SlotKey(id: id, kind: kind)]?.runtime else { return reply(.failure("\(id) has no running \(kind.rawValue)")) }
            runtime.perform(action, payload.map { Double($0).map(JSON.number) ?? .string($0) } ?? .null)
            reply(.ok("sent \(action) to \(id)/\(kind.rawValue)"))
        case .call(let id, let method, let arguments):
            call(id, method, arguments, trace) { response in
                guard case .ok(let text) = response, case .string(let string)? = try? JSON.parse(text) else { return reply(response) }
                reply(.ok(string))
            }
        }
    }

    private func call(_ id: PluginID, _ method: String, _ arguments: [String], _ trace: Trace, _ reply: @escaping (Response) -> Void) {
        guard let slot = handlerSlot(id) else { return reply(.failure("\(id) is not enabled")) }
        var answered = false
        let once: (Response) -> Void = { response in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                reply(response)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Request.callTimeout) {
            once(.failure("\(id) \(method) did not finish within \(Int(Request.callTimeout)) seconds"))
        }
        withRuntime(slot, trace) { runtime in
            guard let runtime else { return once(.failure("\(id) did not load")) }
            runtime.call(method, arguments, reply: once)
        }
    }

    private func surfaceSlot(_ id: PluginID) -> PluginSlot? {
        catalog.plugins[id]?.manifest.kinds.lazy.filter(\.isSurface).compactMap { self.slots[SlotKey(id: id, kind: $0)] }.first
    }

    private func pointerDisplay() -> String? {
        let pointer = NSEvent.mouseLocation
        return displays.first { NSMouseInRect(pointer, $0.frame, false) }?.id
    }

    private func toggle(_ id: PluginID, _ trace: Trace, _ reply: @escaping (Response) -> Void) {
        if surfaceSlot(id)?.visible == true { reply(hide(id, trace)) } else { summon(id, trace, reply) }
    }

    private func summon(_ id: PluginID, _ trace: Trace, _ reply: @escaping (Response) -> Void) {
        guard let slot = surfaceSlot(id) else { return reply(.failure("no enabled surface \(id)")) }
        if let reason = slot.disabledReason { return reply(.failure("\(id) is disabled: \(reason)")) }
        if slot.visible, slot.runtime != nil { return reply(.ok("shown")) }
        slot.visible = true
        slot.focused = pointerDisplay()
        slot.waiters.append(reply)
        if let runtime = slot.runtime {
            runtime.setScene(scene(for: slot), trace)
        } else if slot.candidate == nil {
            load(slot, trace)
        }
    }

    private func hide(_ id: PluginID, _ trace: Trace) -> Response {
        guard let slot = surfaceSlot(id) else { return .failure("no enabled surface \(id)") }
        guard slot.visible else { return .ok("hidden") }
        slot.visible = false
        if id == .onboarding { recordOnboardingDismissed() }
        if slot.bundle.manifest.keepLoaded, let runtime = slot.runtime {
            unmount(slot.key)
            runtime.setScene(scene(for: slot), trace)
        } else {
            stop(slot)
        }
        slot.answerWaiters(.ok("hidden"))
        return .ok("hidden")
    }

    private func doctorRuntime() -> DoctorRuntime {
        let states = slots.values.sorted { $0.key.description < $1.key.description }.map { slot -> (String, String?) in
            switch slot.phase {
            case .failed(let reason): return (slot.key.description, "failed: \(reason)")
            case .disabled(let reason): return (slot.key.description, "disabled after repeated failures: \(reason)")
            case .stopped, .running: return (slot.key.description, nil)
            }
        }
        return DoctorRuntime(pid: getpid(), enabled: enabledManifests, pluginStates: states)
    }

    private var enabledManifests: [PluginManifest] { resolution.enabled.compactMap { catalog.plugins[$0]?.manifest } }

    private func listing() -> String {
        var lines = catalog.sortedIDs.map { id -> String in
            let bundle = catalog.plugins[id]!
            let manifest = bundle.manifest
            let states = manifest.kinds.map { kind -> String in
                guard resolution.enabled.contains(id) else { return "\(kind.rawValue):disabled" }
                guard let slot = slots[SlotKey(id: id, kind: kind)] else { return "\(kind.rawValue):\(kind == .barWidget ? "not-in-bar" : "inactive")" }
                switch slot.phase {
                case .running: return "\(kind.rawValue):\(kind.isSurface ? (slot.visible ? "shown" : "paused") : "running")"
                case .stopped: return "\(kind.rawValue):\(kind.isSurface ? "hidden" : "stopped")"
                case .failed(let reason): return "\(kind.rawValue):failed(\(reason))"
                case .disabled(let reason): return "\(kind.rawValue):disabled(\(reason))"
                }
            }
            return [id.rawValue, manifest.version, bundle.origin == .builtin ? "builtin" : "user", states.joined(separator: " ")].joined(separator: "\t")
        }
        lines += catalog.problems.map { "\($0.directory.lastPathComponent)\t-\tinvalid\t\($0.reason)" }
        return lines.joined(separator: "\n")
    }
}

extension Palette.Mode {
    init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension Node {
    var summary: String {
        switch content {
        case .row(let children), .column(let children), .scroll(let children, _), .button(let children, _):
            return children.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        case .text(let value), .icon(let value), .image(let value): return value.replacingOccurrences(of: " ", with: "_") + ":" + (style ?? "default")
        case .slider(let value), .progress(let value): return "\(kind.rawValue)=\(value)"
        case .input(let input): return "input=\(input.value)"
        case .spacer: return ""
        }
    }
}
