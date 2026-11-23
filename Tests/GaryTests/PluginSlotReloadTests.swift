import Foundation
@testable import gary
@testable import GaryCore
import Testing

@MainActor
struct PluginSlotReloadTests {
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

    @Test func `a reload that fails leaves the running version's manifest in charge of hiding and surface addresses`() throws {
        let lifecycle = Lifecycle()
        let panel = try key("test.panel", .panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel)])
        _ = lifecycle.show(in: panel)
        let first = try lifecycle.newest
        lifecycle.loaded(first, panel)
        try lifecycle.sync([panel: bundle("test.panel", .panel, version: "2", keepLoaded: true, surfaces: ["main", "osd"])])
        let candidate = try lifecycle.newest
        #expect(lifecycle.slots[panel]?.bundle.manifest.version == "1")
        lifecycle.failed(candidate, panel)
        #expect(lifecycle.slots[panel]?.bundle.manifest.version == "1")
        #expect(try lifecycle.slots.surfaceSlot(#require(SurfaceAddress("test.panel:osd"))) == nil)
        lifecycle.hide(in: panel)
        #expect(first.stopped)
    }

    @Test func `a reload's manifest takes over when it loads, and a rejected one waits for new files instead of the next sync`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        try lifecycle.sync([service: bundle("test.service", .service)])
        try lifecycle.loaded(lifecycle.newest, service, shows: [])
        try lifecycle.sync([service: bundle("test.service", .service, version: "2")])
        try lifecycle.failed(lifecycle.newest, service)
        try lifecycle.sync([service: bundle("test.service", .service, version: "2")])
        #expect(lifecycle.made.count == 2)
        lifecycle.perform(lifecycle.slots.reload(service))
        let second = try lifecycle.newest
        #expect(second.bundle.manifest.version == "2")
        lifecycle.loaded(second, service, shows: [])
        #expect(lifecycle.slots[service]?.bundle.manifest.version == "2")
    }

    @Test func `a sync that reloads a slot for new settings loads it once, whether or not its bundle changed`() throws {
        let lifecycle = Lifecycle()
        let service = try key("test.service", .service)
        try lifecycle.sync([service: bundle("test.service", .service)])
        try lifecycle.loaded(lifecycle.newest, service, shows: [])
        try lifecycle.perform(lifecycle.slots.sync([service: bundle("test.service", .service)], reloading: [service]))
        #expect(lifecycle.made.count == 2)
        try lifecycle.perform(lifecycle.slots.sync([service: bundle("test.service", .service, version: "2")], reloading: [service]))
        #expect(lifecycle.made.count == 3)
        #expect(try lifecycle.newest.bundle.manifest.version == "2")
    }
}
