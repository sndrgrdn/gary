import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct KeyEventTests {
    @Test(arguments: [
        "a", "A", "!", " ", "+", "ç", "up", "down", "left", "right", "enter", "escape", "tab", "backspace", "delete", "home", "end",
        "pageup", "pagedown", "shift+tab", "cmd+k", "cmd++", "ctrl+alt+cmd+a", "alt+shift+left", "cmd+enter",
    ])
    func `a key name makes an event that onKey names the same`(name: String) throws {
        let event = try #require(NSEvent.keyDown(named: name, windowNumber: 0))
        #expect(event.keyName == name)
    }

    @Test(arguments: ["", "space", "shift+a", "cmd+K", "cmd+", "cmd+shift+k", "alt+ctrl+a", "f1", "ab"])
    func `a name onKey never gets makes no event`(name: String) {
        #expect(NSEvent.keyDown(named: name, windowNumber: 0) == nil)
    }

    @Test func `keys sent to a focused surface fill its input and the rest reach onKey`() throws {
        let theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        var sent: [String] = []
        let host = try TreeHostingView(
            tree: MountedTree(root: Node.parse(JSON.parse(#"{"type":"input","key":"query","change":"filter","submit":"go"}"#)), theme: theme),
            onAction: { sent.append("\($0.name) \($0.payload.string ?? "")") },
            onDismiss: { sent.append("dismiss") },
        )
        let panel = makeSurfacePanel(level: 0)
        panel.focusable = true
        panel.setFrame(CGRect(x: -2000, y: -2000, width: 200, height: 40), display: false)
        panel.contentView = host
        panel.onKey = { sent.append("key \($0)") }
        panel.orderFrontRegardless()
        defer { panel.close() }
        panel.makeKey()
        host.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(host.descendants(NSTextField.self).first)
        for name in ["s", "A", "backspace", "f", "down", "enter"] {
            try NSApp.sendEvent(#require(NSEvent.keyDown(named: name, windowNumber: panel.windowNumber)))
        }
        #expect(sent == ["filter s", "filter sA", "filter s", "filter sf", "key down", "go sf"])
    }
}
