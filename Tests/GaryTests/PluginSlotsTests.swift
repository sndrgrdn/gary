import Foundation
@testable import gary
@testable import GaryCore
import Testing

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

    @Test func `a surface address names the missing surface, so hide fails for a kind name as summon does`() throws {
        let lifecycle = Lifecycle()
        let widget = try key("test.multi", .barWidget)
        let overlay = try key("test.multi", .overlay)
        let manifest = try PluginManifest(
            id: #require(PluginID("test.multi")), name: "multi", version: "1", kinds: [.barWidget, .overlay],
            entryPoints: [.barWidget: "widget.js", .overlay: "overlay.js"], keepLoaded: false, subscriptions: [:], uses: [],
            hotkeys: [], surfaces: [.overlay: ["speedtest"]],
        )
        let multi = PluginBundle(manifest: manifest, directory: URL(fileURLWithPath: "/p/multi"), origin: .user)
        lifecycle.sync([widget: multi, overlay: multi])
        let kindName = try #require(SurfaceAddress("test.multi:overlay"))
        #expect(lifecycle.slots.surfaceSlot(kindName) == nil)
        #expect(lifecycle.slots.missingSurface(kindName) == "test.multi has no surface overlay")
        #expect(try lifecycle.slots.missingSurface(#require(SurfaceAddress("test.none:main"))) == "no enabled surface test.none")
    }

    @Test func `a panel that a call or hotkey loads with nothing shown stops a minute after the last one`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        _ = lifecycle.use(panel)
        let runtime = try lifecycle.newest
        lifecycle.loaded(runtime, panel, shows: [])
        lifecycle.advance(by: 30)
        _ = lifecycle.use(panel)
        lifecycle.advance(by: 59)
        #expect(!runtime.stopped)
        lifecycle.advance(by: 1)
        #expect(runtime.stopped)
        #expect(lifecycle.state(panel) == "stopped")
    }

    @Test func `a panel that a call loads keeps running while it is shown or keepLoaded`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        let kept = try key("test.kept", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel), kept: bundle("test.kept", .panel, keepLoaded: true)])
        _ = lifecycle.use(panel)
        let shown = try lifecycle.newest
        lifecycle.loaded(shown, panel, shows: [])
        _ = lifecycle.show(in: panel)
        _ = lifecycle.use(kept)
        let loaded = try lifecycle.newest
        lifecycle.loaded(loaded, kept, shows: [])
        lifecycle.advance(by: 120)
        #expect(!shown.stopped)
        #expect(!loaded.stopped)
    }
}
