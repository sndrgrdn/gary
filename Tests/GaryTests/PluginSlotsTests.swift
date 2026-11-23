import Foundation
@testable import gary
@testable import GaryCore
import Testing

final class FakeRuntime: SlotRuntime {
    let bundle: PluginBundle
    let initialScene: Scene
    var scene: Scene
    var started = false
    var stopped = false

    init(bundle: PluginBundle, scene: Scene) {
        self.bundle = bundle
        initialScene = scene
        self.scene = scene
    }
}

@MainActor
final class Lifecycle {
    typealias Effect = PluginSlots<FakeRuntime>.Effect

    private(set) var clock = 0.0
    private(set) var made: [FakeRuntime] = []
    private(set) var presented: [SlotKey] = []
    private(set) var unmounted: [String] = []
    private(set) var syncs = 0
    private var timers: [(due: Double, transition: () -> [Effect])] = []
    private(set) lazy var slots = PluginSlots<FakeRuntime>(
        make: { _, bundle, scene in
            let runtime = FakeRuntime(bundle: bundle, scene: scene)
            self.made.append(runtime)
            return runtime
        },
        scene: { _, shown in Scene(shown: shown) },
        clock: { self.clock },
    )

    var newest: FakeRuntime {
        get throws { try #require(made.last) }
    }

    func perform(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case let .start(runtime): runtime.started = true
            case let .stop(runtime): runtime.stopped = true
            case let .setScene(runtime, scene): runtime.scene = scene
            case let .present(key, _): presented.append(key)
            case let .unmount(key, surface): unmounted.append("\(key)" + (surface.map { ":\($0)" } ?? ""))
            case let .answer(waiters, response): waiters.forEach { $0(response) }
            case let .later(delay, _, transition): timers.append((clock + delay, transition))
            case .sync: syncs += 1
            }
        }
    }

    func advance(by seconds: Double) {
        let target = clock + seconds
        while let index = timers.indices.filter({ timers[$0].due <= target }).min(by: { timers[$0].due < timers[$1].due }) {
            let timer = timers.remove(at: index)
            clock = max(clock, timer.due)
            perform(timer.transition())
        }
        clock = target
    }

    func sync(_ wanted: [SlotKey: PluginBundle]) {
        perform(slots.sync(wanted))
    }

    func loaded(_ runtime: FakeRuntime, _ key: SlotKey, shows surfaces: [String] = [SurfaceAddress.main]) {
        perform(slots.loaded(runtime, at: key, RuntimeOutput(trees: Dictionary(uniqueKeysWithValues: surfaces.map { ($0, [:]) }))))
    }

    func failed(_ runtime: FakeRuntime, _ key: SlotKey, _ reason: String = "boom") {
        perform(slots.failed(runtime, at: key, reason))
    }

    func show(in key: SlotKey, _ surface: String = SurfaceAddress.main) -> Replies {
        let replies = Replies()
        perform(slots.show(surface, in: key, ShownSurface(), replies.add))
        return replies
    }

    func hide(in key: SlotKey, _ surface: String = SurfaceAddress.main) {
        perform(slots.hide(surface, in: key))
    }

    func use(_ key: SlotKey) -> Uses {
        let uses = Uses()
        perform(slots.use(key) { uses.runtimes.append($0) })
        return uses
    }

    func state(_ key: SlotKey) -> String {
        switch slots[key]?.phase {
        case nil: "none"
        case .stopped: "stopped"
        case .running: "running"
        case let .failed(reason): "failed(\(reason))"
        case .disabled: "disabled"
        }
    }
}

@MainActor
final class Replies {
    private(set) var all: [String] = []

    func add(_ response: Response) {
        switch response {
        case let .ok(text): all.append(text)
        case let .failure(reason): all.append("failure: \(reason)")
        }
    }
}

@MainActor
final class Uses {
    var runtimes: [FakeRuntime?] = []
}

private func bundle(
    _ id: String,
    _ kind: PluginKind,
    version: String = "1",
    keepLoaded: Bool = false,
    surfaces: [String] = [SurfaceAddress.main],
) throws -> PluginBundle {
    let manifest = try PluginManifest(
        id: #require(PluginID(id)), name: id, version: version, kinds: [kind], entryPoints: [kind: "main.js"],
        keepLoaded: keepLoaded, subscriptions: [kind: []], uses: [], hotkeys: [],
        surfaces: kind.isSurface ? [kind: surfaces] : [:],
    )
    return PluginBundle(manifest: manifest, directory: URL(fileURLWithPath: "/p/\(id)"), origin: .user)
}

private func key(_ id: String, _ kind: PluginKind) throws -> SlotKey {
    try SlotKey(id: #require(PluginID(id)), kind: kind)
}

@MainActor
struct PluginSlotsTests {
    @Test func `a service loads when synced and runs once its runtime loads`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        try lifecycle.sync([service: bundle("test.service", .service)])
        #expect(lifecycle.made.count == 1)
        #expect(try lifecycle.newest.started)
        #expect(lifecycle.state(service) == "stopped")
        try lifecycle.loaded(lifecycle.newest, service, shows: [])
        #expect(lifecycle.state(service) == "running")
    }

    @Test func `a panel loads when shown, answers shown once loaded, and stops when its last surface hides`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        #expect(lifecycle.made.isEmpty)
        let replies = lifecycle.show(in: panel)
        let runtime = try lifecycle.newest
        #expect(runtime.initialScene.shown.keys.sorted() == [SurfaceAddress.main])
        #expect(replies.all.isEmpty)
        lifecycle.loaded(runtime, panel)
        #expect(replies.all == ["shown"])
        #expect(lifecycle.presented == [panel])
        lifecycle.hide(in: panel)
        #expect(runtime.stopped)
        #expect(lifecycle.state(panel) == "stopped")
        #expect(lifecycle.unmounted == ["test.panel/panel"])
    }

    @Test func `a keepLoaded panel keeps running when its last surface hides and drops it from its scene`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel, keepLoaded: true)])
        _ = lifecycle.show(in: panel)
        let runtime = try lifecycle.newest
        lifecycle.loaded(runtime, panel)
        lifecycle.hide(in: panel)
        #expect(!runtime.stopped)
        #expect(lifecycle.state(panel) == "running")
        #expect(runtime.scene.shown.isEmpty)
        #expect(lifecycle.unmounted == ["test.panel/panel:main"])
    }

    @Test func `showing a second surface of a running panel sets its scene instead of loading again`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel, surfaces: ["main", "osd"])])
        _ = lifecycle.show(in: panel)
        let runtime = try lifecycle.newest
        lifecycle.loaded(runtime, panel)
        let replies = lifecycle.show(in: panel, "osd")
        #expect(lifecycle.made.count == 1)
        #expect(runtime.scene.shown.keys.sorted() == ["main", "osd"])
        perform(lifecycle, output: runtime, panel)
        #expect(replies.all == ["shown"])
        lifecycle.hide(in: panel, "osd")
        #expect(!runtime.stopped)
        #expect(runtime.scene.shown.keys.sorted() == ["main"])
    }

    private func perform(_ lifecycle: Lifecycle, output runtime: FakeRuntime, _ key: SlotKey) {
        lifecycle.perform(lifecycle.slots.output(runtime, at: key, RuntimeOutput()))
    }

    @Test func `a reload that fails keeps the running version`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        try lifecycle.sync([service: bundle("test.service", .service)])
        let first = try lifecycle.newest
        lifecycle.loaded(first, service, shows: [])
        lifecycle.perform(lifecycle.slots.reload(service))
        let candidate = try lifecycle.newest
        #expect(candidate !== first)
        #expect(lifecycle.slots.isCurrent(first, at: service))
        lifecycle.failed(candidate, service)
        #expect(lifecycle.state(service) == "running")
        #expect(lifecycle.slots[service]?.runtime === first)
        #expect(!lifecycle.slots.isCurrent(candidate, at: service))
    }

    @Test func `a reload that loads replaces the running version`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        try lifecycle.sync([service: bundle("test.service", .service)])
        let first = try lifecycle.newest
        lifecycle.loaded(first, service, shows: [])
        lifecycle.perform(lifecycle.slots.reload(service))
        let second = try lifecycle.newest
        lifecycle.loaded(second, service, shows: [])
        #expect(first.stopped)
        #expect(lifecycle.slots[service]?.runtime === second)
        #expect(!lifecycle.slots.isCurrent(first, at: service))
    }

    @Test func `a failed service restarts a second later and is disabled by a sixth failure within a minute until reloaded`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        try lifecycle.sync([service: bundle("test.service", .service)])
        for attempt in 1...6 {
            #expect(lifecycle.made.count == attempt)
            try lifecycle.failed(lifecycle.newest, service)
            if attempt < 6 {
                #expect(lifecycle.state(service) == "failed(boom)")
                lifecycle.advance(by: 0.5)
                #expect(lifecycle.made.count == attempt)
                lifecycle.advance(by: 0.5)
            }
        }
        #expect(lifecycle.state(service) == "disabled")
        lifecycle.advance(by: 5)
        #expect(lifecycle.made.count == 6)
        lifecycle.perform(lifecycle.slots.reload(service))
        #expect(lifecycle.made.count == 7)
        #expect(lifecycle.state(service) == "stopped")
    }

    @Test func `a failed panel fails its waiters and does not restart`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        let replies = lifecycle.show(in: panel)
        try lifecycle.failed(lifecycle.newest, panel)
        #expect(replies.all == ["failure: test.panel failed: boom"])
        #expect(lifecycle.slots[panel]?.visible == false)
        lifecycle.advance(by: 5)
        #expect(lifecycle.made.count == 1)
    }

    @Test func `a disabled panel refuses to show and gives a call no runtime`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        for _ in 1...6 {
            _ = lifecycle.show(in: panel)
            try lifecycle.failed(lifecycle.newest, panel)
        }
        #expect(lifecycle.show(in: panel).all.first?.hasPrefix("failure: test.panel is disabled:") == true)
        let uses = lifecycle.use(panel)
        #expect(uses.runtimes.map { $0 == nil } == [true])
        #expect(lifecycle.made.count == 6)
    }

    @Test func `a call loads a stopped kind once and runs every waiting call when it loads`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        let first = lifecycle.use(panel)
        let second = lifecycle.use(panel)
        #expect(lifecycle.made.count == 1)
        #expect(first.runtimes.isEmpty)
        let runtime = try lifecycle.newest
        lifecycle.loaded(runtime, panel, shows: [])
        #expect(first.runtimes.map { $0 === runtime } == [true])
        #expect(second.runtimes.map { $0 === runtime } == [true])
        #expect(lifecycle.use(panel).runtimes.map { $0 === runtime } == [true])
    }

    @Test func `a slot that sync drops stops and fails its waiters`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        let replies = lifecycle.show(in: panel)
        let runtime = try lifecycle.newest
        lifecycle.sync([:])
        #expect(runtime.stopped)
        #expect(replies.all == ["failure: test.panel was stopped"])
        #expect(lifecycle.state(panel) == "none")
        #expect(!lifecycle.slots.isCurrent(runtime, at: panel))
    }

    @Test func `a bar asks for a sync when it loads and when it fails`() throws {
        let lifecycle = Lifecycle()
        let bar = try key("test.bar", .bar)
        try lifecycle.sync([bar: bundle("test.bar", .bar)])
        try lifecycle.loaded(lifecycle.newest, bar)
        #expect(lifecycle.syncs == 1)
        try lifecycle.failed(lifecycle.newest, bar)
        #expect(lifecycle.syncs == 2)
    }

    @Test func `a call goes to the first kind in handler order and a surface address to the kind that lists it`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.both", .service)
        let menu = try key("test.both", .menu)
        let manifest = try PluginManifest(
            id: #require(PluginID("test.both")), name: "both", version: "1", kinds: [.menu, .service],
            entryPoints: [.menu: "menu.js", .service: "service.js"], keepLoaded: false, subscriptions: [:], uses: [], hotkeys: [],
            surfaces: [.menu: ["main", "picker"]],
        )
        let both = PluginBundle(manifest: manifest, directory: URL(fileURLWithPath: "/p/both"), origin: .user)
        lifecycle.sync([service: both, menu: both])
        #expect(lifecycle.slots.handler(of: service.id) == service)
        #expect(try lifecycle.slots.surfaceSlot(#require(SurfaceAddress("test.both:picker")))?.key == menu)
        #expect(try lifecycle.slots.surfaceSlot(#require(SurfaceAddress("test.both:other"))) == nil)
        #expect(lifecycle.slots.surfaces(of: menu.id).map(\.key) == [menu])
    }

    @Test func `a changed bundle reloads a running slot and is kept for a stopped surface`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([service: bundle("test.service", .service), panel: bundle("test.panel", .panel)])
        try lifecycle.loaded(lifecycle.newest, service, shows: [])
        try lifecycle.sync([service: bundle("test.service", .service, version: "2"), panel: bundle("test.panel", .panel, version: "2")])
        #expect(lifecycle.made.count == 2)
        #expect(try lifecycle.newest.bundle.manifest.version == "2")
        #expect(lifecycle.slots[panel]?.bundle.manifest.version == "2")
        try lifecycle.sync([service: bundle("test.service", .service, version: "2"), panel: bundle("test.panel", .panel, version: "2")])
        #expect(lifecycle.made.count == 2)
    }
}
