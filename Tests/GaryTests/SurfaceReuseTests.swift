import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct SurfaceReuseTests {
    private let theme: Theme
    private let display = DisplayInfo(id: "display", index: 0, frame: CGRect(x: -4000, y: -4000, width: 1000, height: 800), band: 24)
    private let spec: SurfaceSpec

    init() throws {
        theme = try Self.theme(.dark)
        spec = try SurfaceSpec.parse(JSON.parse(#"{"width":300,"focusable":true}"#), kind: .menu)
    }

    private static func theme(_ mode: Palette.Mode) throws -> Theme {
        try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: mode),
        )
    }

    private static func tree(_ label: String, rows: Int = 40, query: String = "") throws -> Node {
        let items = (0..<rows).map { #"{"type":"text","key":"row\#($0)","text":"\#(label) \#($0)"}"# }.joined(separator: ",")
        return try Node.parse(JSON.parse(#"""
        {"type":"column","padding":8,"children":[
          {"type":"input","key":"query","value":"\#(query)","change":"filter"},
          {"type":"scroll","key":"list","height":120,"children":[\#(items)]}
        ]}
        """#))
    }

    @MainActor private final class Actions {
        var sent: [String] = []
    }

    @MainActor private final class Shown {
        let window = SurfaceWindow()
        let view: TreeHostingView
        private let actions = Actions()

        init(_ tree: Node, _ theme: Theme) {
            view = TreeHostingView(
                tree: MountedTree(root: tree, theme: theme),
                onAction: { [actions] in actions.sent.append("\($0.name) \($0.payload.string ?? "")") },
                onDismiss: { Issue.record("unexpected dismiss") },
            )
        }

        var sent: [String] {
            actions.sent
        }

        var field: NSTextField? {
            view.descendants(NSTextField.self).first
        }

        var scrolled: CGFloat? {
            view.descendants(NSScrollView.self).first.map { $0.contentView.bounds.minY - ($0.documentView?.frame.minY ?? 0) }
        }

        var picture: Data? {
            window.panel.makeFirstResponder(nil)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
    }

    private func open(_ shown: Shown, _ theme: Theme, _ spec: SurfaceSpec? = nil) {
        shown.window.setContent(shown.view)
        shown.window.place(spec ?? self.spec, on: display, origin: nil, level: 0, theme: theme)
        shown.window.show(fade: 0)
        shown.window.focus()
        commit(shown)
    }

    private func commit(_ shown: Shown) {
        for _ in 0..<2 {
            shown.window.panel.contentView?.layoutSubtreeIfNeeded()
            shown.window.panel.displayIfNeeded()
            CATransaction.flush()
        }
    }

    private func hidden(_ shown: Shown) async {
        shown.window.hide(fade: 0)
        while shown.window.panel.isVisible {
            await Task.yield()
        }
    }

    private func use(_ shown: Shown) throws {
        for key in ["s", "a"] {
            try NSApp.sendEvent(#require(NSEvent.keyDown(named: key, windowNumber: shown.window.panel.windowNumber)))
        }
        let scroll = try #require(shown.view.descendants(NSScrollView.self).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY + 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        commit(shown)
    }

    @Test(arguments: ["first", "second"])
    func `a surface shown again draws what a new surface draws, with its input empty and its list at the top`(label: String) async throws {
        let fresh = try Shown(Self.tree(label), theme)
        open(fresh, theme)
        defer { fresh.window.panel.close() }
        fresh.window.panel.orderOut(nil)

        let reused = try Shown(Self.tree("first"), theme)
        open(reused, theme)
        defer { reused.window.panel.close() }
        try use(reused)
        #expect(reused.field?.stringValue == "sa")
        #expect(reused.scrolled != fresh.scrolled)
        #expect(reused.picture != fresh.picture)

        await hidden(reused)
        #expect(!reused.window.panel.isVisible)
        try reused.view.reopen(Self.tree(label), theme: theme)
        open(reused, theme)

        #expect(reused.window.panel.isVisible)
        #expect(reused.window.panel.alphaValue == 1)
        #expect(reused.field?.stringValue.isEmpty == true)
        #expect(reused.scrolled == fresh.scrolled)
        #expect(reused.picture == fresh.picture)
    }

    @Test(arguments: [#"{"width":300,"focusable":true}"#, #"{"width":300,"height":200,"focusable":true}"#])
    func `a surface shown again focuses its input, so typing reaches it and the other keys reach onKey`(size: String) async throws {
        let spec = try SurfaceSpec.parse(JSON.parse(size), kind: .menu)
        let shown = try Shown(Self.tree("first"), theme)
        open(shown, theme, spec)
        defer { shown.window.panel.close() }
        try use(shown)
        #expect(shown.sent == ["filter s", "filter sa"])

        await hidden(shown)
        try shown.view.reopen(Self.tree("first"), theme: theme)
        open(shown, theme, spec)
        var keys: [String] = []
        shown.window.panel.onKey = { keys.append($0) }
        for key in ["x", "down"] {
            try NSApp.sendEvent(#require(NSEvent.keyDown(named: key, windowNumber: shown.window.panel.windowNumber)))
        }

        #expect(shown.sent == ["filter s", "filter sa", "filter x"])
        #expect(keys == ["down"])
    }

    @Test func `a surface shown again with the text its plugin kept has it selected, so typing replaces it`() async throws {
        let shown = try Shown(Self.tree("first", query: "kept"), theme)
        open(shown, theme)
        defer { shown.window.panel.close() }
        try NSApp.sendEvent(#require(NSEvent.keyDown(named: "right", windowNumber: shown.window.panel.windowNumber)))

        await hidden(shown)
        try shown.view.reopen(Self.tree("first", query: "kept"), theme: theme)
        open(shown, theme)
        try NSApp.sendEvent(#require(NSEvent.keyDown(named: "x", windowNumber: shown.window.panel.windowNumber)))

        #expect(shown.sent == ["filter x"])
    }

    @Test func `a surface shown again after the theme changed draws the new theme`() async throws {
        let light = try Self.theme(.light)
        let fresh = try Shown(Self.tree("first"), light)
        open(fresh, light)
        defer { fresh.window.panel.close() }
        fresh.window.panel.orderOut(nil)

        let reused = try Shown(Self.tree("first"), theme)
        open(reused, theme)
        defer { reused.window.panel.close() }
        #expect(reused.picture != fresh.picture)
        await hidden(reused)
        try reused.view.reopen(Self.tree("first"), theme: light)
        open(reused, light)

        #expect(reused.picture == fresh.picture)
    }

    @Test func `a surface shown again before its hide finished stays on screen`() async throws {
        let shown = try Shown(Self.tree("first", rows: 2), theme)
        open(shown, theme)
        defer { shown.window.panel.close() }
        let later = try Shown(Self.tree("second", rows: 2), theme)
        open(later, theme)
        defer { later.window.panel.close() }

        shown.window.hide(fade: 0)
        open(shown, theme)
        await hidden(later)

        #expect(shown.window.panel.isVisible)
        #expect(shown.window.panel.alphaValue == 1)
    }

    @Test func `a hidden surface is handed back for a minute, counted from its last hide, and then closed`() async throws {
        var timers: [(delay: TimeInterval, fire: @MainActor @Sendable () -> Void)] = []
        let parked = ParkedMounts { timers.append(($0, $1)) }
        let key = try MountKey(slot: SlotKey(id: #require(PluginID("test.menu")), kind: .menu), surface: SurfaceAddress.main, display: display.id)
        let other = MountKey(slot: key.slot, surface: "second", display: display.id)
        let shown = try Shown(Self.tree("first", rows: 2), theme)
        let mount = ParkedMount(window: shown.window, view: shown.view)
        open(shown, theme)
        defer { shown.window.panel.close() }

        parked.park(key, mount, fade: 0)
        while shown.window.panel.isVisible {
            await Task.yield()
        }
        #expect(timers.map(\.delay) == [60])
        #expect(parked.take(other) == nil)
        #expect(parked.take(key)?.window === shown.window)
        #expect(parked.take(key) == nil)

        open(shown, theme)
        parked.park(key, mount, fade: 0)
        timers[0].fire()
        #expect(parked.take(key)?.window === shown.window)

        parked.park(key, mount, fade: 0)
        timers[2].fire()
        #expect(parked.take(key) == nil)
    }
}
