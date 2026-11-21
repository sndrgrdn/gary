import Foundation
@testable import GaryCore
import Testing

struct PaletteTests {
    @Test func parsesAnOmarchyColorsTomlAndKeepsUnknownKeys() {
        let file = PaletteFile.parse("""
        # a comment
        mode = "light"

        accent = "#1E66F5"
        background = '#eff1f5'
        foreground = "#4c4f69"   # trailing comment
        selection_background = #dc8a78
        color15 = "#6c6f85"
        icon_mark = "#8839ef80"
        """)
        #expect(file.mode == .light)
        #expect(file.ignored == [])
        #expect(file.colors == [
            "accent": RGBA(hex: "#1e66f5")!, "background": RGBA(hex: "#eff1f5")!, "foreground": RGBA(hex: "#4c4f69")!,
            "selection_background": RGBA(hex: "#dc8a78")!, "color15": RGBA(hex: "#6c6f85")!, "icon_mark": RGBA(hex: "#8839ef80")!,
        ])
    }

    @Test func ignoresBadLinesAndNamesEach() {
        let file = PaletteFile.parse("""
        background = "#101315"
        [colors]
        border = "rgba(798186ee) rgba(caccccee)"
        theme_type = "dark"
        mode = "sepia"
        short = "#1234"
        open = "#ffffff
        two words = "#ffffff"
        trailing = "#ffffff" junk
        foreground = "#ccc"
        background = "#000000"
        accent = "blue"
        """)
        #expect(file.colors == ["background": RGBA(hex: "#000000")!, "foreground": RGBA(hex: "#cccccc")!])
        #expect(file.mode == nil)
        #expect(file.ignored == [
            "line 2: not key = \"value\"",
            "line 5: mode must be light or dark",
            "line 7: open has an unterminated string",
            "line 8: \"two words\" is not a bare key",
            "line 9: trailing has text after its value",
            "line 12: accent is not #rgb, #rrggbb or #rrggbbaa",
        ])
    }

    @Test func keepsTheColoursAndModeOfAFullOmarchyPaletteWithAliasesAndNonColourValues() {
        let file = PaletteFile.parse("""
        accent = "#798186"
        active_border_color = "#a8adb0"
        active_tab_background = "#798186"
        background = "#101315"
        bg = "#101315"
        blue = "#798186"
        bright_blue = "#5d6367"
        bright_cyan = "#707070"
        bright_fg = "#a5aeb4"
        bright_foreground = "#a5aeb4"
        bright_green = "#343d41"
        bright_magenta = "#9a9a9a"
        bright_purple = "#9a9a9a"
        bright_red = "#de6145"
        bright_yellow = "#c9c2b4"
        brown = "#6d6e6e"
        color0 = "#101315"
        color1 = "#565d60"
        color10 = "#343d41"
        color11 = "#c9c2b4"
        color12 = "#5d6367"
        color13 = "#9a9a9a"
        color14 = "#707070"
        color15 = "#a5aeb4"
        color2 = "#9fa5a9"
        color3 = "#d9dbdc"
        color4 = "#798186"
        color5 = "#aeaeae"
        color6 = "#707070"
        color7 = "#cacccc"
        color8 = "#4b4e55"
        color9 = "#de6145"
        cursor = "#a5aeb4"
        cyan = "#707070"
        dark_background = "#0c0e10"
        dark_bg = "#0c0e10"
        dark_fg = "#4b4e55"
        dark_foreground = "#4b4e55"
        darker_background = "#080a0b"
        darker_bg = "#080a0b"
        fg = "#cacccc"
        foreground = "#cacccc"
        green = "#9fa5a9"
        hyprland_active_border = "rgba(798186ee) rgba(caccccee)"
        hyprland_inactive_border = "rgb(1e1e1e)"
        light_fg = "#cbc2be"
        light_foreground = "#cbc2be"
        lighter_background = "#101315"
        lighter_bg = "#101315"
        magenta = "#aeaeae"
        mode = "dark"
        muted = "#4b4e55"
        orange = "#d9dbdc"
        purple = "#aeaeae"
        red = "#565d60"
        selection = "#343d41"
        selection_background = "#343d41"
        selection_foreground = "#a5aeb4"
        theme_type = "dark"
        yellow = "#d9dbdc"
        """)
        #expect(file.mode == .dark)
        #expect(file.ignored == [])
        #expect(file.colors.count == 56)
        #expect(file.colors["background"] == RGBA(hex: "#101315") && file.colors["bg"] == file.colors["background"])
        #expect(file.colors["color15"] == RGBA(hex: "#a5aeb4"))
        #expect(file.colors["hyprland_active_border"] == nil && file.colors["theme_type"] == nil && file.colors["mode"] == nil)
    }

    @Test func theModeComesFromTheFileThenItsBackgroundThenTheSystem() {
        let dark = RGBA(hex: "#101315")!, light = RGBA(hex: "#fffcf0")!
        #expect(Palette(PaletteFile(mode: .light, colors: ["background": dark], ignored: []), system: .dark).mode == .light)
        #expect(Palette(PaletteFile(mode: nil, colors: ["background": light], ignored: []), system: .dark).mode == .light)
        #expect(Palette(PaletteFile(mode: nil, colors: ["background": dark], ignored: []), system: .light).mode == .dark)
        #expect(Palette(PaletteFile(mode: nil, colors: ["accent": dark], ignored: []), system: .light).mode == .light)
        #expect(Palette(PaletteFile(mode: nil, colors: ["accent": dark], ignored: []), system: .dark).mode == .dark)
    }

    @Test func missingBaseKeysComeFromTheBuiltInPaletteOfTheMode() {
        let accent = RGBA(hex: "#ff8800")!
        let palette = Palette(PaletteFile(mode: .light, colors: ["accent": accent, "yellow": accent], ignored: []), system: .dark)
        let builtin = Palette.builtin(.light).colors
        #expect(palette.colors == ["accent": accent, "yellow": accent, "background": builtin["background"]!, "foreground": builtin["foreground"]!])
    }

    @Test func withoutAFileThePaletteIsTheBuiltInOneForTheSystemAppearance() {
        for mode in [Palette.Mode.light, .dark] {
            let palette = Palette(nil, system: mode)
            #expect(palette.mode == mode)
            #expect(palette.colors == Palette.builtin(mode).colors)
        }
        #expect(Palette(nil, system: .light).background.isLight)
        #expect(!Palette(nil, system: .dark).background.isLight)
    }

    @Test func theBuiltInPalettesAreCompleteAndMatchTheirMode() {
        for mode in [Palette.Mode.light, .dark] {
            let builtin = Palette.builtin(mode)
            #expect(builtin.ignored == [])
            #expect(builtin.mode == mode)
            for key in Palette.baseKeys { #expect(builtin.colors[key] != nil, "\(mode) \(key)") }
        }
    }
}

struct ColorExprTests {
    private let names = ["fg": RGBA(red: 1, green: 1, blue: 1), "bg": RGBA(red: 0, green: 0, blue: 0)]

    private func evaluate(_ text: String) -> RGBA? {
        ColorExpr(text)?.evaluate { names[$0] }
    }

    @Test func evaluatesHexNamesAndFunctions() {
        #expect(evaluate("#ff000080") == RGBA(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
        #expect(evaluate("fg") == names["fg"])
        #expect(evaluate("mix(fg, bg, 0.25)") == RGBA(red: 0.75, green: 0.75, blue: 0.75))
        #expect(evaluate("alpha( fg , 0.5 )") == RGBA(red: 1, green: 1, blue: 1, alpha: 0.5))
        #expect(evaluate("contrast(bg)") == RGBA(red: 1, green: 1, blue: 1))
        #expect(evaluate("contrast(#fafafa)") == RGBA(red: 0, green: 0, blue: 0))
        #expect(evaluate("alpha(mix(fg, #000000, 0.5), 1)") == RGBA(red: 0.5, green: 0.5, blue: 0.5))
    }

    @Test func anUnknownNameAnywhereLeavesTheWholeColourUnresolved() {
        #expect(evaluate("teal") == nil)
        #expect(evaluate("mix(fg, teal, 0.5)") == nil)
    }

    @Test func rejectsMalformedColours() {
        for bad in ["", "#12", "mix(fg, bg)", "mix(fg, bg, 2)", "alpha(fg, -1)", "blend(fg, bg, 0.5)", "fg bg", "mix(fg, bg, 0.5", "1abc", "fg)"] {
            #expect(ColorExpr(bad) == nil, "\(bad)")
        }
    }

    @Test func rejectsNestingDeeperThanSixteenInsteadOfOverflowingTheStack() {
        func nested(_ depth: Int) -> String { String(repeating: "contrast(", count: depth) + "fg" + String(repeating: ")", count: depth) }
        #expect(evaluate(nested(15)) == RGBA(red: 0, green: 0, blue: 0))
        #expect(ColorExpr(nested(16)) == nil)
        #expect(ColorExpr(nested(100_000)) == nil)
    }

    @Test func formatsHexWithAlphaOnlyWhenTranslucent() {
        #expect(RGBA(hex: "#7aa2f7")!.hex == "#7aa2f7")
        #expect(RGBA(red: 1, green: 0, blue: 0, alpha: 0.25).hex == "#ff000040")
    }
}
