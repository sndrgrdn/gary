import Foundation
import Testing
@testable import GaryCore

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
        short = "#123"
        open = "#ffffff
        two words = "#ffffff"
        trailing = "#ffffff" junk
        foreground = "#cacccc"
        background = "#000000"
        """)
        #expect(file.colors == ["background": RGBA(hex: "#000000")!, "foreground": RGBA(hex: "#cacccc")!])
        #expect(file.mode == nil)
        #expect(file.ignored == [
            "line 2: not key = \"value\"",
            "line 3: border is not #rrggbb or #rrggbbaa",
            "line 4: theme_type is not #rrggbb or #rrggbbaa",
            "line 5: mode must be light or dark",
            "line 6: short is not #rrggbb or #rrggbbaa",
            "line 7: open has an unterminated string",
            "line 8: \"two words\" is not a bare key",
            "line 9: trailing has text after its value",
        ])
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

    @Test func formatsHexWithAlphaOnlyWhenTranslucent() {
        #expect(RGBA(hex: "#7aa2f7")!.hex == "#7aa2f7")
        #expect(RGBA(red: 1, green: 0, blue: 0, alpha: 0.25).hex == "#ff000040")
    }
}
