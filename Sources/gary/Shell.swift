import AppKit
import GaryCore
import GarySocket

enum Paths {
    static let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gary")
    static let userPlugins = config.appending(path: "plugins")
    static let shellConfig = config.appending(path: "shell.json")
    static let userTheme = config.appending(path: "theme.json")
    static let builtinPlugins = Bundle.main.resourceURL!.appending(path: "plugins")
    static let defaultTheme = Bundle.main.resourceURL!.appending(path: "theme.json")
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
    }

    let key: SlotKey
    var bundle: PluginBundle
    var phase = Phase.stopped
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

private struct Mount {
    var node: Node
    var view: NSView
}

final class Shell {
    private let hub = StateHub()
    private let levels = SurfaceLevels.forSystem(ProcessInfo.processInfo.operatingSystemVersion)
    private var theme: Theme
    private var renderer: ViewRenderer
    private var themePayload: JSON?
    private var config = ShellConfig.defaults
    private var catalog = PluginCatalog()
    private var resolution: ShellConfig.Resolution
    private var slots: [SlotKey: PluginSlot] = [:]
    private var displays: [DisplayInfo] = []
    private var bars: [String: BarWindow] = [:]
    private var windows: [MountKey: SurfaceWindow] = [:]
    private var mounts: [MountKey: Mount] = [:]
    private var clickMonitors: [Any] = []
    private var server: LineServer?
    private var watcher: FileWatcher?
    private var providers: [AnyObject] = []
    private var signals: [DispatchSourceSignal] = []

    init() throws {
        theme = try Theme.parse(try JSON.parse(Data(contentsOf: Paths.defaultTheme)))
        renderer = ViewRenderer(theme: theme)
        resolution = config.resolve(catalog)
    }

    func start() throws {
        server = try LineServer(path: socketPath) { [weak self] line in self?.serve(line) ?? Response.failure("shutting down").line }
        try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
        reloadTheme()
        loadConfig()
        scan()

        let clock = ClockProvider(hub: hub), battery = BatteryProvider(hub: hub)
        providers = [clock, battery]
        clock.start()
        battery.start()

        rebuildDisplays(Trace("start"))
        sync(Trace("start"))

        watcher = FileWatcher(root: Paths.config) { [weak self] paths, trace in self?.filesChanged(paths, trace) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildDisplays(Trace("screens"))
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signals.append(source)
        }
        log("ready pid=\(getpid()) levels=bar:\(levels.bar),\(SurfaceLayer.allCases.map { "\($0.rawValue):\(levels.level($0))" }.joined(separator: ",")) plugins=\(catalog.sortedIDs.map(\.rawValue).joined(separator: ","))")
    }

    private func quit() {
        server?.stop()
        unlink(socketPath)
        exit(0)
    }


    private func scan() {
        catalog = PluginCatalog.scan(builtin: Paths.builtinPlugins, user: Paths.userPlugins)
        for problem in catalog.problems { log("plugin \(problem.directory.path): \(problem.reason)") }
        resolve()
    }

    private func resolve() {
        resolution = config.resolve(catalog)
        for warning in resolution.warnings { log("shell.json: \(warning)") }
    }

    private var usesBuiltinBar: Bool {
        guard let id = resolution.barPlugin else { return true }
        if case .failed? = slots[SlotKey(id: id, kind: .bar)]?.phase { return true }
        return false
    }

    private func sync(_ trace: Trace) {
        if usesBuiltinBar == bars.isEmpty { rebuildDisplays(trace) }
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
                if isLive(slot) { load(slot, trace) }
            } else {
                let slot = PluginSlot(key: key, bundle: bundle)
                slots[key] = slot
                if !key.kind.isSurface { load(slot, trace) }
            }
        }
        arrangeBars()
        commitFrame()
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
            settings: config.settings[key.id] ?? .object([:]), hub: hub
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
            slot.answerWaiters(.ok(slot.visible ? "shown" : "loaded"))
            if key.kind == .bar { sync(trace) }
        case .output(let output, let trace):
            guard slot.runtime === runtime else { return }
            present(slot, output, trace)
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
        let mutations: Int
        if let mounted = mounts[key] {
            if let patch = reconcile(mounted.node, tree) {
                let (view, count) = renderer.apply(patch, to: mounted.view, onAction: onAction)
                mounts[key] = Mount(node: tree, view: view)
                mutations = count
            } else {
                mutations = 0
            }
        } else {
            mounts[key] = Mount(node: tree, view: renderer.build(tree, onAction: onAction))
            mutations = -1
        }
        place(key)
        if tracing {
            let end = now()
            log(String(format: "commit plugin=%@ display=%@ cause=%@ since_ms=%.3f apply_ms=%.3f mut=%d tree=%@",
                       slot.key.id.rawValue, display, trace.cause, (end - trace.start) * 1000, (end - started) * 1000, mutations, tree.summary))
        }
    }

    private func place(_ key: MountKey) {
        guard let view = mounts[key]?.view, let slot = slots[key.slot] else { return }
        if key.slot.kind == .barWidget {
            guard let bar = bars[key.display] else { return }
            for (section, ids) in resolution.bar where ids.contains(key.slot.id) {
                bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), display: key.display)]?.view })
            }
            return
        }
        guard let display = displays.first(where: { $0.id == key.display }) else { return }
        let window = windows[key] ?? SurfaceWindow()
        let isNew = windows[key] == nil
        windows[key] = window
        window.setContent(view)
        if key.slot.kind == .bar {
            var spec = SurfaceSpec.defaults(for: .bar)
            spec.anchors = Edges(top: true, bottom: false, left: true, right: true)
            spec.height = .points(display.band)
            spec.exclusionMode = .ignore
            window.place(spec, on: display, level: levels.bar)
        } else if let spec = slot.surface {
            window.place(spec, on: display, level: levels.level(spec.layer))
        }
        if isNew {
            window.show(fade: fade(key.slot))
            watchClicks()
        }
    }

    private func unmount(_ key: MountKey) {
        if let window = windows.removeValue(forKey: key) {
            window.close(fade: fade(key.slot))
            mounts[key] = nil
        } else {
            mounts.removeValue(forKey: key)?.view.removeFromSuperview()
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
        for bar in bars.values {
            for (section, ids) in resolution.bar {
                bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), display: bar.display.id)]?.view })
            }
        }
    }

    private func commitFrame() {
        let panels = bars.values.map(\.panel) + windows.values.map(\.panel)
        for panel in panels where panel.isVisible {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        CATransaction.flush()
    }


    private func rebuildDisplays(_ trace: Trace) {
        for bar in bars.values { bar.close() }
        bars = [:]
        for key in mounts.keys where key.slot.kind == .barWidget { mounts[key] = nil }
        displays = NSScreen.screens.enumerated().map { $1.display(index: $0, theme: theme) }
        for (screen, display) in zip(NSScreen.screens, displays) where usesBuiltinBar {
            let bar = BarWindow(display: display, level: levels.bar)
            bar.layout(on: screen, theme: theme)
            bars[display.id] = bar
        }
        for slot in slots.values {
            if slot.candidate != nil { load(slot, trace) }
            slot.runtime?.setScene(scene(for: slot), trace)
        }
        log("screens: " + NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height)) notch=\($0.notch != nil)" }.joined(separator: "; "))
    }

    @discardableResult
    private func reloadTheme() -> Response {
        do {
            var override = themePayload ?? .object([:])
            if FileManager.default.fileExists(atPath: Paths.userTheme.path) {
                override = override.merging(try JSON.parse(Data(contentsOf: Paths.userTheme)))
            }
            let next = try Theme.parse(try JSON.parse(Data(contentsOf: Paths.defaultTheme)), override: override)
            guard next != theme else { return .ok("theme unchanged") }
            let bandChanged = next.bar.height != theme.bar.height
            theme = next
            renderer = ViewRenderer(theme: theme)
            if bandChanged {
                rebuildDisplays(Trace("theme"))
            }
            for mount in mounts.values { renderer.restyle(mount.view, mount.node) }
            for key in mounts.keys { place(key) }
            commitFrame()
            log("theme applied")
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

    private func reloadConfig(_ trace: Trace) -> Response {
        let previous = config
        let response = loadConfig()
        guard config != previous else { return response }
        resolve()
        for slot in slots.values where config.settings[slot.key.id] != previous.settings[slot.key.id] && isLive(slot) {
            load(slot, trace)
        }
        sync(trace)
        return response
    }

    private func filesChanged(_ paths: Set<String>, _ trace: Trace) {
        let root = Paths.config.resolvingSymlinksInPath().path
        let plugins = Paths.userPlugins.resolvingSymlinksInPath().path + "/"
        var rescan = false
        var reloads = Set<SlotKey>()
        for path in paths {
            if path == root + "/theme.json" {
                reloadTheme()
            } else if path == root + "/shell.json" {
                _ = reloadConfig(trace)
            } else if path.hasPrefix(plugins) {
                let relative = path.dropFirst(plugins.count)
                let directory = String(relative.prefix { $0 != "/" })
                let owners = slots.values.filter { $0.bundle.origin == .user && $0.bundle.directory.lastPathComponent == directory }
                if owners.isEmpty || relative.hasSuffix("/manifest.json") || !relative.contains("/") {
                    rescan = true
                } else {
                    reloads.formUnion(owners.map(\.key))
                }
            }
        }
        if rescan {
            scan()
            sync(trace)
        }
        for key in reloads {
            guard let slot = slots[key], isLive(slot) else { continue }
            load(slot, trace)
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
        return box.wait(5).line
    }

    private func handle(_ request: Request, reply: @escaping (Response) -> Void) {
        let trace = Trace("ipc-\(request.verb)")
        switch request {
        case .ping:
            reply(.ok("pong"))
        case .summon(let id):
            summon(id, trace, reply)
        case .hide(let id):
            reply(hide(id, trace))
        case .toggle(let id):
            if surfaceSlot(id)?.visible == true { reply(hide(id, trace)) } else { summon(id, trace, reply) }
        case .reloadPlugins(let id):
            let live = slots.values.filter { (id == nil || $0.key.id == id) && isLive($0) }
            guard id == nil || !live.isEmpty else { return reply(.failure("\(id!) is not loaded")) }
            for slot in live { load(slot, trace) }
            reply(.ok("reloading \(live.count)"))
        case .rescanPlugins:
            scan()
            sync(trace)
            reply(.ok("\(catalog.plugins.count) plugins, \(catalog.problems.count) problems"))
        case .reloadConfig:
            reply(reloadConfig(trace))
        case .applyTheme(let payload):
            themePayload = payload
            reply(reloadTheme())
        case .listPlugins:
            reply(.ok(listing()))
        case .call(let id, let method, let arguments):
            guard let runtime = slots.values.compactMap({ $0.key.id == id ? $0.runtime : nil }).first else {
                return reply(.failure("\(id) is not running"))
            }
            DispatchQueue.global(qos: .userInitiated).async { reply(runtime.call(method, arguments)) }
        }
    }

    private func surfaceSlot(_ id: PluginID) -> PluginSlot? {
        catalog.plugins[id]?.manifest.kinds.lazy.filter(\.isSurface).compactMap { self.slots[SlotKey(id: id, kind: $0)] }.first
    }

    private func pointerDisplay() -> String? {
        let pointer = NSEvent.mouseLocation
        return displays.first { NSMouseInRect(pointer, $0.frame, false) }?.id
    }

    private func summon(_ id: PluginID, _ trace: Trace, _ reply: @escaping (Response) -> Void) {
        guard let slot = surfaceSlot(id) else { return reply(.failure("no enabled surface \(id)")) }
        if slot.visible, slot.runtime != nil { return reply(.ok("shown")) }
        slot.visible = true
        slot.focused = pointerDisplay()
        slot.waiters.append(reply)
        if let runtime = slot.runtime {
            runtime.setScene(scene(for: slot), trace)
            slot.answerWaiters(.ok("shown"))
        } else if slot.candidate == nil {
            load(slot, trace)
        }
    }

    private func hide(_ id: PluginID, _ trace: Trace) -> Response {
        guard let slot = surfaceSlot(id) else { return .failure("no enabled surface \(id)") }
        guard slot.visible else { return .ok("hidden") }
        slot.visible = false
        if slot.bundle.manifest.keepLoaded, let runtime = slot.runtime {
            unmount(slot.key)
            runtime.setScene(scene(for: slot), trace)
        } else {
            stop(slot)
        }
        slot.answerWaiters(.ok("hidden"))
        return .ok("hidden")
    }

    private func listing() -> String {
        var lines = catalog.sortedIDs.map { id -> String in
            let bundle = catalog.plugins[id]!
            let manifest = bundle.manifest
            let states = manifest.kinds.map { kind -> String in
                guard resolution.enabled.contains(id) else { return "\(kind.rawValue):disabled" }
                guard let slot = slots[SlotKey(id: id, kind: kind)] else { return "\(kind.rawValue):\(kind == .barWidget ? "not-in-bar" : "inactive")" }
                switch slot.phase {
                case .running: return "\(kind.rawValue):\(kind.isSurface && !slot.visible ? "paused" : "running")"
                case .stopped: return "\(kind.rawValue):stopped"
                case .failed(let reason): return "\(kind.rawValue):failed(\(reason))"
                }
            }
            return [id.rawValue, manifest.version, bundle.origin == .builtin ? "builtin" : "user", states.joined(separator: " ")].joined(separator: "\t")
        }
        lines += catalog.problems.map { "\($0.directory.lastPathComponent)\t-\tinvalid\t\($0.reason)" }
        return lines.joined(separator: "\n")
    }
}

extension Node {
    var summary: String {
        switch content {
        case .row(let children), .column(let children), .scroll(let children), .button(let children, _):
            return children.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        case .text(let value), .icon(let value), .image(let value): return value.replacingOccurrences(of: " ", with: "_") + ":" + (style ?? "default")
        case .slider(let value), .progress(let value): return "\(kind.rawValue)=\(value)"
        case .input(let input): return "input=\(input.value)"
        case .spacer: return ""
        }
    }
}
