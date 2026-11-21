import Foundation
@testable import GaryCore
import Testing

struct ThemeTests {
    private static let bundled = try! JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/theme.json")))

    private static let tokens = ["background", "foreground", "accent", "dim", "bright", "good", "bad", "panel", "hover", "selected", "bar"]

    private func theme(_ override: String? = nil, palette: String? = nil) throws -> Theme {
        try Theme.parse(Self.bundled, override: override.map { try JSON.parse($0) }, palette: Palette(palette.map(PaletteFile.parse), system: .dark))
    }

    private func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        (max(a.luminance, b.luminance) + 0.05) / (min(a.luminance, b.luminance) + 0.05)
    }

    @Test func parsesHexColors() {
        #expect(RGBA(hex: "#ff8000") == RGBA(red: 1, green: 128.0 / 255, blue: 0, alpha: 1))
        #expect(RGBA(hex: "#00000080")?.alpha == 128.0 / 255)
        #expect(RGBA(hex: "#f80") == RGBA(hex: "#ff8800"))
        for bad in ["ff8000", "#ff80", "#gg8000", "#ff800000ff", "#+f8000", "#f8", "#g80"] { #expect(RGBA(hex: bad) == nil) }
    }

    @Test(arguments: [
        ("dark", "background = \"#101010\"\nforeground = \"#d0d0d0\"\naccent = \"#e0a030\""),
        ("light", "background = \"#fafafa\"\nforeground = \"#333333\"\naccent = \"#3060c0\""),
    ])
    func aPaletteOfBackgroundForegroundAndAccentGivesEveryTokenReadably(_ mode: String, _ palette: String) throws {
        let theme = try theme(palette: palette)
        let colors = theme.colors, background = theme.palette.background, foreground = theme.palette.foreground, accent = theme.palette.colors["accent"]!
        #expect(theme.mode.rawValue == mode)
        #expect(theme.warnings == [])
        for token in Self.tokens { #expect(colors[token] != nil, "\(token)") }
        #expect(colors["background"] == background && colors["bar"] == background && theme.bar.background == background)
        #expect(colors["foreground"] == foreground && colors["accent"] == accent)
        for token in ["foreground", "dim", "bright", "good", "bad"] {
            #expect(contrast(colors[token]!, background) >= 3, "\(token) on the background")
        }
        #expect(contrast(colors["dim"]!, background) < contrast(foreground, background))
        #expect(contrast(colors["bright"]!, background) > contrast(foreground, background))
        let panel = colors["panel"]!
        #expect(panel.alpha == 1)
        #expect(contrast(panel, background) > 1 && contrast(panel, background) < 1.5)
        #expect(colors["selected"] == RGBA(red: accent.red, green: accent.green, blue: accent.blue, alpha: 0.25))
        #expect(colors["hover"] == RGBA(red: foreground.red, green: foreground.green, blue: foreground.blue, alpha: 0.1))
    }

    @Test(arguments: [Palette.Mode.light, .dark])
    func theBuiltInPalettesReadOnTheirOwnBackground(_ mode: Palette.Mode) throws {
        let theme = try Theme.parse(Self.bundled, palette: Palette(nil, system: mode))
        #expect(theme.mode == mode && theme.warnings == [])
        for token in Self.tokens { #expect(theme.colors[token] != nil, "\(token)") }
        for token in ["foreground", "bright", "good", "bad", "accent"] {
            #expect(contrast(theme.colors[token]!, theme.bar.background) >= 3, "\(token)")
        }
        #expect(contrast(theme.colors["dim"]!, theme.bar.background) >= 2.5)
    }

    @Test func thePaletteKeysTheThemeNamesWinOverItsMixes() throws {
        let theme = try theme(palette: """
        background = "#101315"
        foreground = "#cacccc"
        accent = "#798186"
        dark_foreground = "#4b4e55"
        bright_foreground = "#a5aeb4"
        lighter_background = "#1a1d20"
        green = "#9fa5a9"
        red = "#de6145"
        color1 = "#565d60"
        color2 = "#9fa5a9"
        """)
        #expect(theme.colors["dim"] == RGBA(hex: "#4b4e55"))
        #expect(theme.colors["bright"] == RGBA(hex: "#a5aeb4"))
        #expect(theme.colors["panel"] == RGBA(hex: "#1a1d20"))
        #expect(theme.colors["good"] == RGBA(hex: "#9fa5a9"))
        #expect(theme.colors["bad"] == RGBA(hex: "#de6145"))
    }

    @Test func surfacesDefaultToTheSystemFontAndTheBarKeepsMonospace() throws {
        let theme = try theme()
        #expect(theme.resolve(nil).font.family == .system)
        #expect(theme.resolve("title").font.family == .system)
        #expect(theme.resolve("mono").font.family == .monospaced)
        #expect(theme.inBar.resolve(nil).font.family == .monospaced)
        #expect(theme.inBar.resolve("active").font == FontToken(family: .monospaced, size: 12, weight: .bold))
        let custom = try self.theme(#"{"bar":{"fonts":{"body":{"family":"Menlo","size":11}}}}"#)
        #expect(custom.inBar.resolve(nil).font == FontToken(family: .named("Menlo"), size: 11, weight: .regular))
        #expect(custom.resolve(nil).font.family == .system)
    }

    @Test func terminalColoursStandInForNamedOnes() throws {
        let theme = try theme(palette: """
        background = "#1a1b26"
        foreground = "#a9b1d6"
        accent = "#7aa2f7"
        color1 = "#f7768e"
        color2 = "#9ece6a"
        """)
        #expect(theme.colors["bad"] == RGBA(hex: "#f7768e"))
        #expect(theme.colors["good"] == RGBA(hex: "#9ece6a"))
    }

    @Test func stylesAndNodePropertiesReachPaletteKeysAndThemeNamesWin() throws {
        let theme = try theme(##"{"colors": {"accent": "#ff0000"}}"##, palette: """
        background = "#1a1b26"
        foreground = "#a9b1d6"
        accent = "#7aa2f7"
        yellow = "#e0af68"
        """)
        #expect(theme.resolve(nil, StyleProps(color: "yellow")).color == RGBA(hex: "#e0af68"))
        #expect(theme.resolve(nil, StyleProps(background: "alpha(yellow, 0.5)")).background == RGBA(red: 0xe0 / 255, green: 0xaf / 255, blue: 0x68 / 255, alpha: 0.5))
        #expect(theme.resolve(nil, StyleProps(color: "accent")).color == RGBA(hex: "#ff0000"))
        #expect(theme.colors["selected"] == RGBA(red: 1, green: 0, blue: 0, alpha: 0.25))
        #expect(theme.resolve(nil, StyleProps(color: "no-such-color")).color == theme.style("default").color)
    }

    @Test func anOverrideColourThatDoesNotResolveFallsBackToTheBundledOne() throws {
        let override = #"{"colors": {"dim": "purple", "warn": "orange"}}"#
        let without = try theme(override)
        #expect(without.colors["dim"] == RGBA(hex: "#565f89"))
        #expect(without.colors["warn"] == nil)
        #expect(without.warnings == ["colors.warn: no colour resolves with this palette"])
        let with = try theme(override, palette: "purple = \"#9d7cd8\"\norange = \"#ff9e64\"")
        #expect(with.colors["dim"] == RGBA(hex: "#9d7cd8"))
        #expect(with.colors["warn"] == RGBA(hex: "#ff9e64"))
    }

    @Test func unknownColourNamesInStylesAreWarnings() throws {
        let theme = try theme(#"{"styles": {"active": {"color": "teal"}, "panel": {"background": "fog"}}}"#)
        #expect(theme.warnings == ["styles.active.color: no colour teal with this palette", "styles.panel.background: no colour fog with this palette"])
        #expect(theme.style("active").color == theme.style("default").color)
        #expect(theme.style("panel").background == nil)
    }

    @Test func pluginsGetTheModeTheResolvedColoursAndTheRawPalette() throws {
        let json = try theme(palette: "background = \"#fafafa\"\nforeground = \"#333333\"\naccent = \"#3060c0\"\nicon_mark = \"#8839ef\"").json
        #expect(json["mode"] == .string("light"))
        #expect(json["colors"]?["selected"] == .string("#3060c040"))
        #expect(json["colors"]?["bar"] == .string("#fafafa"))
        #expect(json["palette"] == .object(["background": .string("#fafafa"), "foreground": .string("#333333"), "accent": .string("#3060c0"), "icon_mark": .string("#8839ef")]))
    }

    @Test func theBundledThemeResolvesEveryStyle() throws {
        let theme = try theme()
        #expect(theme.style("active").color == RGBA(hex: "#7aa2f7"))
        #expect(theme.style("active").font == FontToken(family: .system, size: 13, weight: .semibold))
        #expect(theme.bar.background == RGBA(hex: "#1a1b26"))
        #expect(theme.spacing.item == 8)
    }

    @Test func stylesInheritWhatTheyLeaveOutFromDefault() throws {
        let theme = try theme()
        #expect(theme.style("dim").font == theme.style("default").font)
        #expect(theme.style("dim").color == RGBA(hex: "#565f89"))
    }

    @Test func unknownAndMissingStyleNamesFallBackToDefault() throws {
        let theme = try theme()
        #expect(theme.style("no-such-style") == theme.style("default"))
        #expect(theme.style(nil) == theme.style("default"))
    }

    @Test func anOverrideChangesOneTokenAndKeepsTheRest() throws {
        let theme = try theme(##"{"colors": {"accent": "#ff0000"}, "bar": {"height": 28}}"##)
        #expect(theme.style("active").color == RGBA(hex: "#ff0000"))
        #expect(theme.style("good").color == RGBA(hex: "#9ece6a"))
        #expect(theme.bar.height == 28)
        #expect(theme.bar.background == RGBA(hex: "#1a1b26"))
    }

    @Test func nodePropertiesOverrideTheNamedStyleAndHoverOverridesBoth() throws {
        let theme = try theme()
        let props = StyleProps(padding: Insets(4), fontSize: 20, background: "accent", color: "#ff0000")
        let resolved = theme.resolve("panel", props)
        #expect(resolved.padding == Insets(4) && resolved.radius == 12)
        #expect(resolved.background == RGBA(hex: "#7aa2f7"))
        #expect(resolved.color == RGBA(hex: "#ff0000"))
        #expect(resolved.font == FontToken(family: .system, size: 20, weight: .regular))
        #expect(theme.resolve(nil, props, hover: "hover").background == RGBA(red: 0xa9 / 255, green: 0xb1 / 255, blue: 0xd6 / 255, alpha: 0.1))
        #expect(theme.resolve(nil, StyleProps(color: "no-such-color")).color == theme.style("default").color)
        #expect(theme.motion.fade == 0.15)
    }

    @Test func aStyleCanUseAHexLiteral() throws {
        #expect(try theme(##"{"styles": {"warn": {"color": "#ffcc00"}}}"##).style("warn").color == RGBA(hex: "#ffcc00"))
    }

    @Test func rejectsBrokenTokensWithTheirPath() {
        let cases: [(String, ThemeError)] = [
            (#"{"colors": {"accent": "mix(blue"}}"#, ThemeError(path: "colors.accent", reason: "must be \(ColorExpr.syntax)")),
            (#"{"colors": {"dim": ["dark_foreground", 3]}}"#, ThemeError(path: "colors.dim[1]", reason: "must be \(ColorExpr.syntax)")),
            (##"{"styles": {"active": {"color": "#12"}}}"##, ThemeError(path: "styles.active.color", reason: "must be \(ColorExpr.syntax)")),
            (#"{"styles": {"active": {"font": "huge"}}}"#, ThemeError(path: "styles.active.font", reason: "unknown font huge")),
            (#"{"fonts": {"body": {"weight": "extra"}}}"#, ThemeError(path: "fonts.body.weight", reason: "unknown weight extra")),
            (#"{"bar": {"height": -1}}"#, ThemeError(path: "bar.height", reason: "must be a non-negative number")),
            (#"{"spacing": 8}"#, ThemeError(path: "spacing", reason: "must be an object")),
            (#"{"styles": {"panel": {"radius": -2}}}"#, ThemeError(path: "styles.panel.radius", reason: "must be a non-negative number")),
            (#"{"motion": {"fade": "slow"}}"#, ThemeError(path: "motion.fade", reason: "must be a non-negative number")),
        ]
        for (override, error) in cases {
            #expect(throws: error, "\(override)") { try theme(override) }
        }
    }

    @Test func fontFamiliesMapToSystemMonospacedOrANamedFont() throws {
        let theme = try theme(#"{"fonts": {"body": {"family": "system"}, "title": {"family": "JetBrainsMono NFM"}}}"#)
        #expect(theme.fonts["body"]?.family == .system)
        #expect(theme.fonts["title"]?.family == .named("JetBrainsMono NFM"))
    }
}
