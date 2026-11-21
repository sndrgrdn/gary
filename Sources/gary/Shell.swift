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
    let target: Target
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
    private var bars: [String: BarWindow] = [:]
    private var panels: [PluginID: PanelWindow] = [:]
    private var mounts: [MountKey: Mount] = [:]
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

        rebuildBars(Trace("start"))
        sync(Trace("start"))

        watcher = FileWatcher(root: Paths.config) { [weak self] paths, trace in self?.filesChanged(paths, trace) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildBars(Trace("screens"))
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signals.append(source)
        }
        log("ready pid=\(getpid()) levels=bar:\(levels.bar),panel:\(levels.panel) plugins=\(catalog.sortedIDs.map(\.rawValue).joined(separator: ","))")
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
        for id in resolution.enabled {
            let unsupported = catalog.plugins[id]!.manifest.kinds.filter { $0 != .barWidget && $0 != .panel }
            if !unsupported.isEmpty { log("plugin \(id): kinds \(unsupported.map(\.rawValue)) are not supported yet") }
        }
    }

    private func sync(_ trace: Trace) {
        var wanted: [SlotKey: PluginBundle] = [:]
        for id in resolution.bar.values.joined() { wanted[SlotKey(id: id, kind: .barWidget)] = catalog.plugins[id] }
        for id in resolution.enabled where catalog.plugins[id]!.manifest.kinds.contains(.panel) {
            wanted[SlotKey(id: id, kind: .panel)] = catalog.plugins[id]
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
                if key.kind == .barWidget { load(slot, trace) }
            }
        }
        arrangeBars()
        commitFrame()
    }

    private func isLive(_ slot: PluginSlot) -> Bool {
        slot.key.kind == .barWidget || slot.visible || slot.runtime != nil
    }

    private func targets(for slot: PluginSlot) -> [Target] {
        slot.key.kind == .panel ? [.panel] : bars.values.map { .bar($0.display) }
    }

    private func load(_ slot: PluginSlot, _ trace: Trace) {
        slot.candidate?.stop()
        let key = slot.key
        let runtime = PluginRuntime(
            bundle: slot.bundle, kind: key.kind, targets: targets(for: slot),
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
        if slot.key.kind == .panel { panels[slot.key.id]?.hide() }
        slot.answerWaiters(.failure("\(slot.key.id) was stopped"))
    }

    private func handle(_ event: RuntimeEvent, from runtime: PluginRuntime, _ key: SlotKey) {
        guard let slot = slots[key], slot.candidate === runtime || slot.runtime === runtime else {
            runtime.stop()
            return
        }
        switch event {
        case .loaded(let trees, let trace):
            slot.candidate = nil
            slot.runtime?.stop()
            slot.phase = .running(runtime)
            log("plugin \(key): loaded \(slot.bundle.manifest.version)")
            for (target, tree) in trees { mount(slot, target, tree, trace) }
            if key.kind == .panel { slot.answerWaiters(.ok("shown")) }
        case .tree(let target, let tree, let trace):
            guard slot.runtime === runtime else { return }
            mount(slot, target, tree, trace)
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
            if key.kind == .panel {
                panels[key.id]?.hide()
                slot.visible = false
            }
            slot.answerWaiters(.failure("\(key.id) failed: \(reason)"))
            commitFrame()
            log("plugin \(key): failed: \(reason)")
        }
    }

    private func perform(_ action: String, _ key: SlotKey) {
        if tracing { log("action plugin=\(key) action=\(action)") }
        slots[key]?.runtime?.perform(action)
    }


    private func mount(_ slot: PluginSlot, _ target: Target, _ tree: Node, _ trace: Trace) {
        let key = MountKey(slot: slot.key, target: target)
        let slotKey = slot.key
        let onAction: (String) -> Void = { [weak self] action in self?.perform(action, slotKey) }
        let started = now()
        let mutations: Int
        if let mounted = mounts[key] {
            guard let patch = reconcile(mounted.node, tree) else { return }
            let (view, count) = renderer.apply(patch, to: mounted.view, onAction: onAction)
            mounts[key] = Mount(node: tree, view: view)
            mutations = count
            if view !== mounted.view { place(slot, target) }
        } else {
            mounts[key] = Mount(node: tree, view: renderer.build(tree, onAction: onAction))
            mutations = -1
            place(slot, target)
        }
        if case .panel = target, slot.visible, let panel = panels[slot.key.id] {
            panel.fit(theme: theme)
            if !panel.isVisible { panel.show() }
        }
        commitFrame()
        if tracing {
            let end = now()
            log(String(format: "commit plugin=%@ target=%@ cause=%@ since_ms=%.3f apply_ms=%.3f mut=%d tree=%@",
                       slot.key.id.rawValue, target.description, trace.cause, (end - trace.start) * 1000, (end - started) * 1000, mutations, tree.summary))
        }
    }

    private func place(_ slot: PluginSlot, _ target: Target) {
        switch target {
        case .bar(let display):
            guard let bar = bars[display.id] else { return }
            for (section, ids) in resolution.bar where ids.contains(slot.key.id) {
                bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), target: target)]?.view })
            }
        case .panel:
            guard let view = mounts[MountKey(slot: slot.key, target: .panel)]?.view else { return }
            let panel = panels[slot.key.id] ?? PanelWindow(level: levels.panel)
            panels[slot.key.id] = panel
            panel.setContent(view, theme: theme)
        }
    }

    private func unmount(_ key: SlotKey) {
        let removed = mounts.keys.filter { $0.slot == key }
        for mountKey in removed { mounts[mountKey]?.view.removeFromSuperview() }
        for mountKey in removed { mounts[mountKey] = nil }
        if key.kind == .barWidget { arrangeBars() }
    }

    private func arrangeBars() {
        for bar in bars.values {
            let target = Target.bar(bar.display)
            for (section, ids) in resolution.bar {
                bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), target: target)]?.view })
            }
        }
    }

    private func commitFrame() {
        for bar in bars.values {
            bar.panel.contentView?.layoutSubtreeIfNeeded()
            bar.panel.displayIfNeeded()
        }
        for panel in panels.values where panel.isVisible {
            panel.panel.contentView?.layoutSubtreeIfNeeded()
            panel.panel.displayIfNeeded()
        }
        CATransaction.flush()
    }


    private func rebuildBars(_ trace: Trace) {
        for bar in bars.values { bar.close() }
        bars = [:]
        for key in mounts.keys where key.target != .panel { mounts[key] = nil }
        for screen in NSScreen.screens {
            let bar = BarWindow(screen: screen, level: levels.bar)
            bar.layout(on: screen, theme: theme)
            bars[bar.display.id] = bar
        }
        for slot in slots.values where slot.key.kind == .barWidget {
            if slot.candidate != nil { load(slot, trace) }
            slot.runtime?.setTargets(targets(for: slot), trace)
        }
        log("screens: " + NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height)) notch=\($0.notched)" }.joined(separator: "; "))
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
            theme = next
            renderer = ViewRenderer(theme: theme)
            for screen in NSScreen.screens { bars[screen.uuid]?.layout(on: screen, theme: theme) }
            for mount in mounts.values { renderer.restyle(mount.view, mount.node) }
            for panel in panels.values where panel.isVisible { panel.fit(theme: theme) }
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
            if slots[SlotKey(id: id, kind: .panel)]?.visible == true { reply(hide(id, trace)) } else { summon(id, trace, reply) }
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

    private func summon(_ id: PluginID, _ trace: Trace, _ reply: @escaping (Response) -> Void) {
        guard let slot = slots[SlotKey(id: id, kind: .panel)] else { return reply(.failure("no enabled panel \(id)")) }
        if slot.visible, slot.runtime != nil { return reply(.ok("shown")) }
        slot.visible = true
        slot.waiters.append(reply)
        if let runtime = slot.runtime {
            runtime.setTargets([.panel], trace)
            slot.answerWaiters(.ok("shown"))
        } else if slot.candidate == nil {
            load(slot, trace)
        }
    }

    private func hide(_ id: PluginID, _ trace: Trace) -> Response {
        guard let slot = slots[SlotKey(id: id, kind: .panel)] else { return .failure("no enabled panel \(id)") }
        guard slot.visible else { return .ok("hidden") }
        slot.visible = false
        panels[id]?.hide()
        if slot.bundle.manifest.keepLoaded, let runtime = slot.runtime {
            unmount(slot.key)
            runtime.setTargets([], trace)
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
                guard let slot = slots[SlotKey(id: id, kind: kind)] else { return "\(kind.rawValue):\(kind == .barWidget ? "not-in-bar" : "unsupported")" }
                switch slot.phase {
                case .running: return "\(kind.rawValue):\(kind == .panel && !slot.visible ? "paused" : "running")"
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
        case .row(let children), .column(let children): return children.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        case .text(let value), .icon(let value): return value.replacingOccurrences(of: " ", with: "_") + ":" + (style ?? "default")
        case .spacer: return ""
        }
    }
}
