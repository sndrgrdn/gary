@testable import GaryCore
import Testing

struct KeyNameTests {
    private func name(_ code: UInt16, _ characters: String? = nil, _ ignoring: String? = nil, _ modifiers: KeyName.Modifiers = []) -> String? {
        KeyName.name(keyCode: code, characters: characters, ignoringModifiers: ignoring ?? characters, modifiers: modifiers)
    }

    @Test func `names special keys and keeps the old names`() {
        #expect(name(126, "\u{F700}") == "up")
        #expect(name(125, "\u{F701}") == "down")
        #expect(name(123, "\u{F702}") == "left")
        #expect(name(124, "\u{F703}") == "right")
        #expect(name(36, "\r") == "enter")
        #expect(name(76, "\u{3}") == "enter")
        #expect(name(53, "\u{1B}") == "escape")
        #expect(name(48, "\t") == "tab")
        #expect(name(51, "\u{7F}") == "backspace")
    }

    @Test func `typed characters arrive as they are typed`() {
        #expect(name(0, "a") == "a")
        #expect(name(0, "A", "a", .shift) == "A")
        #expect(name(49, " ") == " ")
        #expect(name(18, "!", "1", .shift) == "!")
    }

    @Test func `modifiers prefix the key in A fixed order`() {
        #expect(name(48, "\u{19}", "\t", .shift) == "shift+tab")
        #expect(name(40, "k", "k", .command) == "cmd+k")
        #expect(name(0, "\u{1}", "a", [.command, .control, .option]) == "ctrl+alt+cmd+a")
        #expect(name(0, "\u{1}", "A", [.control, .shift]) == "ctrl+a")
        #expect(name(123, "\u{F702}", nil, [.option, .shift]) == "alt+shift+left")
    }

    @Test func `drops keys without A name or printable character`() {
        #expect(name(122, "\u{F704}") == nil)
        #expect(name(0, nil) == nil)
        #expect(name(0, "") == nil)
    }

    @Test func `an unhandled escape hides A menu or overlay only`() {
        #expect(PluginKind.menu.hides(onUnhandled: "escape"))
        #expect(PluginKind.overlay.hides(onUnhandled: "escape"))
        #expect(!PluginKind.panel.hides(onUnhandled: "escape"))
        #expect(!PluginKind.menu.hides(onUnhandled: "enter"))
        #expect(!PluginKind.menu.hides(onUnhandled: "shift+escape"))
    }
}
