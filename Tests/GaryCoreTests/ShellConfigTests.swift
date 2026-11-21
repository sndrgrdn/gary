import Foundation
@testable import GaryCore
import Testing

struct ShellConfigTests {
    private struct Entry {
        let raw: String
        let origin: PluginOrigin
        let kinds: [PluginKind]

        init(_ raw: String, _ origin: PluginOrigin, _ kinds: [PluginKind]) {
            self.raw = raw
            self.origin = origin
            self.kinds = kinds
        }
    }

    private func id(_ raw: String) throws -> PluginID {
        try #require(PluginID(raw))
    }

    private func catalog(_ entries: [Entry], subscribes: [String: [Topic]] = [:]) throws -> PluginCatalog {
        var catalog = PluginCatalog()
        for entry in entries {
            let pluginID = try id(entry.raw)
            let manifest = PluginManifest(
                id: pluginID, name: entry.raw, version: "1", kinds: entry.kinds,
                entryPoints: Dictionary(uniqueKeysWithValues: entry.kinds.map { ($0, "main.js") }),
                keepLoaded: false, subscribes: subscribes[entry.raw] ?? [], uses: [], hotkeys: [],
            )
            catalog.plugins[pluginID] = PluginBundle(
                manifest: manifest, directory: URL(fileURLWithPath: "/p/\(entry.raw)"), origin: entry.origin,
            )
        }
        return catalog
    }

    private var standard: PluginCatalog {
        get throws {
            try catalog([
                Entry("gary.clock", .builtin, [.barWidget]), Entry("gary.battery", .builtin, [.barWidget]),
                Entry("gary.today", .builtin, [.panel]),
                Entry("acme.weather", .user, [.barWidget]), Entry("acme.notes", .user, [.panel]),
            ])
        }
    }

    private func config(_ text: String) throws -> ShellConfig {
        try ShellConfig.parse(JSON.parse(text))
    }

    @Test func `an empty file keeps the defaults`() throws {
        #expect(try config("{}") == ShellConfig.defaults)
        let resolution = try ShellConfig.defaults.resolve(standard)
        #expect(try resolution.bar == [.left: [], .center: [], .right: [id("gary.battery"), id("gary.clock")]])
        #expect(try resolution.enabled == Set(["gary.clock", "gary.battery", "gary.today"].map(id)))
        #expect(resolution.warnings.isEmpty)
    }

    @Test func `a user bar replaces the default bar whole`() throws {
        let parsed = try config(#"{"bar": {"left": ["gary.clock"]}}"#)
        #expect(try parsed.bar == [.left: [id("gary.clock")], .center: [], .right: []])
        #expect(try parsed.resolve(standard).bar[.right]?.isEmpty == true)
        #expect(try parsed.resolve(standard).enabled.contains(id("gary.battery")))
    }

    @Test func `the bar reveals the menu bar unless turned off which keeps the default sections`() throws {
        #expect(ShellConfig.defaults.revealMenuBar)
        let parsed = try config(#"{"bar": {"revealMenuBar": false}}"#)
        #expect(!parsed.revealMenuBar)
        #expect(parsed.bar == ShellConfig.defaults.bar)
    }

    @Test func `a third party plugin runs only when named`() throws {
        #expect(try !ShellConfig.defaults.resolve(standard).enabled.contains(id("acme.weather")))
        let named = try config(#"{"bar": {"left": ["acme.weather"]}, "plugins": ["acme.notes"]}"#).resolve(standard)
        #expect(try named.enabled.isSuperset(of: [id("acme.weather"), id("acme.notes")]))
        #expect(try named.bar[.left] == [id("acme.weather")])
    }

    @Test func `disabling removes A plugin everywhere`() throws {
        let resolution = try config(#"{"plugins": ["acme.notes"], "disabledPlugins": ["gary.battery", "gary.today", "acme.notes"]}"#)
            .resolve(standard)
        #expect(try !resolution.enabled.contains(id("gary.battery")))
        #expect(try !resolution.enabled.contains(id("gary.today")))
        #expect(try !resolution.enabled.contains(id("acme.notes")))
        #expect(try resolution.bar[.right] == [id("gary.clock")])
        #expect(resolution.warnings.isEmpty)
    }

    @Test func `the bar skips unknown non widget and repeated entries with warnings`() throws {
        let resolution = try config(#"{"bar": {"left": ["acme.ghost", "gary.today", "gary.clock"], "right": ["gary.clock"]}}"#).resolve(standard)
        #expect(try resolution.bar == [.left: [id("gary.clock")], .center: [], .right: []])
        #expect(resolution.warnings == [
            "bar.left: no plugin acme.ghost", "bar.left: gary.today is not a bar widget", "bar.right: gary.clock is already in the bar",
        ])
    }

    @Test func `one enabled bar plugin replaces the built in bar`() throws {
        #expect(try ShellConfig.defaults.resolve(standard).barPlugin == nil)
        let bars = try catalog([Entry("acme.top", .user, [.bar]), Entry("acme.alt", .user, [.bar, .service]), Entry("acme.off", .user, [.bar])])
        let resolution = try config(#"{"bar": {"right": []}, "plugins": ["acme.top", "acme.alt"]}"#).resolve(bars)
        #expect(try resolution.barPlugin == id("acme.alt"))
        #expect(resolution.warnings == ["acme.top is a bar too; acme.alt replaces the built-in bar"])
        #expect(try config(#"{"plugins": ["acme.top", "acme.alt"], "disabledPlugins": ["acme.alt"]}"#).resolve(bars).barPlugin == id("acme.top"))
    }

    @Test func `subscriptions to plugins that are missing or off are warnings`() throws {
        let plugins = try catalog(
            [Entry("acme.counter", .user, [.service]), Entry("acme.view", .user, [.barWidget]), Entry("acme.off", .user, [.service])],
            subscribes: ["acme.view": [.capability("clock"), .plugin(id("acme.counter")), .plugin(id("acme.off")), .plugin(id("acme.ghost"))]],
        )
        let resolution = try config(#"{"bar": {"left": ["acme.view"]}, "plugins": ["acme.counter"]}"#).resolve(plugins)
        #expect(resolution.warnings == [
            "acme.view subscribes to acme.off, which is not enabled",
            "acme.view subscribes to acme.ghost, which is not installed",
        ])
    }

    @Test func `settings are kept per plugin`() throws {
        let parsed = try config(#"{"settings": {"gary.clock": {"hour12": true}}}"#)
        #expect(try parsed.settings[id("gary.clock")] == .object(["hour12": .bool(true)]))
    }

    @Test func `rejects malformed files with their path`() {
        let cases: [(String, ShellConfigError)] = [
            ("[]", ShellConfigError(path: "root", reason: "must be an object")),
            (#"{"bar": []}"#, ShellConfigError(path: "bar", reason: "must be an object")),
            (#"{"bar": {"top": []}}"#, ShellConfigError(path: "bar.top", reason: "is not left, center, right or revealMenuBar")),
            (#"{"bar": {"revealMenuBar": "no"}}"#, ShellConfigError(path: "bar.revealMenuBar", reason: "must be true or false")),
            (#"{"bar": {"left": ["Clock"]}}"#, ShellConfigError(path: "bar.left[0]", reason: "is not a plugin id")),
            (#"{"disabledPlugins": "gary.clock"}"#, ShellConfigError(path: "disabledPlugins", reason: "must be an array of plugin ids")),
            (#"{"settings": {"clock": {}}}"#, ShellConfigError(path: "settings.clock", reason: "is not a plugin id")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try config(text) }
        }
    }
}

struct ShellConfigChangeTests {
    private let widget: PluginID

    init() throws {
        widget = try #require(PluginID("acme.weather"))
    }

    private func apply(_ change: ShellConfig.Change, to text: String) throws -> JSON {
        try ShellConfig.applying(change, to: JSON.parse(text))
    }

    @Test func `enabling A bar widget keeps the default bar and puts it first on the right`() throws {
        let next = try apply(.enable(widget, inBar: true), to: "{}")
        #expect(try ShellConfig.parse(next).bar == [
            .left: [],
            .center: [],
            .right: [widget, #require(PluginID("gary.battery")), #require(PluginID("gary.clock"))],
        ])
        #expect(next["plugins"] == nil && next["disabledPlugins"] == nil)
        #expect(try ShellConfig.applying(.enable(widget, inBar: true), to: next) == next)
    }

    @Test func `enabling another kind names it in plugins and clears A disable`() throws {
        let next = try apply(
            .enable(widget, inBar: false),
            to: #"{"disabledPlugins": ["acme.weather"], "settings": {"acme.weather": {"unit": "c"}}}"#,
        )
        #expect(next["plugins"] == .array([.string("acme.weather")]))
        #expect(next["disabledPlugins"] == .array([]))
        #expect(next["settings"]?["acme.weather"]?["unit"] == .string("c"))
        #expect(next["bar"] == nil)
    }

    @Test func `disabling keeps the placement and removing drops every mention but settings`() throws {
        let text = #"{"bar": {"left": ["acme.weather"]}, "plugins": ["acme.weather"], "settings": {"acme.weather": {}}}"#
        let disabled = try apply(.disable(widget), to: text)
        #expect(try ShellConfig.parse(disabled).disabledPlugins == [widget])
        #expect(try ShellConfig.parse(disabled).bar[.left] == [widget])
        let removed = try ShellConfig.applying(.remove(widget), to: disabled)
        let config = try ShellConfig.parse(removed)
        #expect(config.bar[.left]?.isEmpty == true && config.plugins.isEmpty && config.disabledPlugins.isEmpty)
        #expect(config.settings[widget] == .object([:]))
    }

    @Test func `editing the bar keeps reveal menu bar`() throws {
        let next = try apply(.enable(widget, inBar: true), to: #"{"bar": {"revealMenuBar": false}}"#)
        #expect(next["bar"]?["revealMenuBar"] == .bool(false))
        #expect(try ShellConfig.parse(next).bar[.right]?.first == widget)
    }

    @Test func `refuses to edit an invalid file`() {
        #expect(throws: ShellConfigError.self) { try apply(.enable(widget, inBar: true), to: #"{"bar": []}"#) }
    }
}
