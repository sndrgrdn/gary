import Foundation
@testable import GaryCore
import Testing

struct PaletteBuiltinTests {
    @Test func `the built in palettes hold their published colours`() {
        #expect(Palette.builtin(.dark) == PaletteFile.parse("""
        mode = "dark"
        background = "#1a1b26"
        foreground = "#a9b1d6"
        accent = "#7aa2f7"
        dark_foreground = "#565f89"
        bright_foreground = "#c0caf5"
        lighter_background = "#24283b"
        green = "#9ece6a"
        red = "#f7768e"
        """))
        #expect(Palette.builtin(.light) == PaletteFile.parse("""
        mode = "light"
        background = "#f4f4f6"
        foreground = "#383a42"
        accent = "#2e6fd9"
        dark_foreground = "#80838d"
        bright_foreground = "#16171c"
        lighter_background = "#ffffff"
        green = "#3d8b40"
        red = "#d73a49"
        """))
    }

    @Test(arguments: [Palette.Mode.light, .dark])
    func `background and foreground come from the file or else the built in palette`(_ mode: Palette.Mode) throws {
        let builtin = Palette.builtin(mode).colors
        let own = try #require(RGBA(hex: "#123456"))
        let partial = Palette(PaletteFile(mode: mode, colors: ["foreground": own], ignored: []), system: mode)
        #expect(partial.foreground == own)
        #expect(partial.background == builtin["background"])
        let bare = Palette(nil, system: mode)
        #expect(bare.background == builtin["background"] && bare.foreground == builtin["foreground"])
    }
}
