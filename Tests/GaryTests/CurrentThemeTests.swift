import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor struct CurrentThemeTests {
    private let folder = ConfigFolder()

    private func loaded(_ system: Palette.Mode) throws -> CurrentTheme {
        let theme = try CurrentTheme(files: folder.files, system: system)
        theme.loadPalette()
        _ = try theme.reload()
        return theme
    }

    @Test func `follows the Mac's appearance without a palette.toml, and a second report of the same appearance changes nothing`() throws {
        let theme = try loaded(.light)
        #expect(theme.value.mode == .light)

        #expect(theme.follow(.dark))
        #expect(try theme.reload())
        #expect(theme.value.mode == .dark)

        #expect(!theme.follow(.dark))
        #expect(try !theme.reload())
    }

    @Test func `a palette.toml sets the colors and its own mode, whatever the Mac's appearance`() throws {
        try folder.write("palette.toml", "background = \"#ffffff\"\nforeground = \"#111111\"\naccent = \"#ff8800\"\n")
        let theme = try loaded(.dark)
        #expect(theme.value.mode == .light)
        #expect(theme.value.color("accent") == RGBA(hex: "#ff8800"))

        try folder.remove("palette.toml")
        theme.loadPalette()
        #expect(try theme.reload())
        #expect(theme.value.mode == .dark)
    }

    @Test func `an applied payload changes the theme over the built-in one, theme.json wins where both set a key, and no payload drops it`() throws {
        try folder.write("theme.json", ##"{"colors": {"accent": "#00ff00"}}"##)
        let theme = try loaded(.dark)
        let before = theme.value

        #expect(try theme.apply(JSON.parse(##"{"colors": {"accent": "#ff0000", "bad": "#0000ff"}}"##)))
        #expect(theme.value.color("accent") == RGBA(hex: "#00ff00"))
        #expect(theme.value.color("bad") == RGBA(hex: "#0000ff"))

        #expect(try theme.apply(nil))
        #expect(theme.value == before)
    }

    @Test func `a theme.json that fails keeps the theme Gary shows until the file is fixed`() throws {
        let theme = try loaded(.dark)
        let before = theme.value
        try folder.write("theme.json", ##"{"colors": {"accent": 42}}"##)
        #expect(throws: ThemeError.self) { try theme.reload() }
        #expect(theme.value == before)

        try folder.write("theme.json", ##"{"colors": {"accent": "#ff0000"}}"##)
        #expect(try theme.reload())
        #expect(theme.value.color("accent") == RGBA(hex: "#ff0000"))
    }
}
