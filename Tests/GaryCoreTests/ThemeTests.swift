import Foundation
import Testing
@testable import GaryCore

struct ThemeTests {
    private static let bundled = try! JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/theme.json")))

    private func theme(_ override: String? = nil) throws -> Theme {
        try Theme.parse(Self.bundled, override: override.map { try JSON.parse($0) })
    }

    @Test func parsesHexColors() {
        #expect(RGBA(hex: "#ff8000") == RGBA(red: 1, green: 128.0 / 255, blue: 0, alpha: 1))
        #expect(RGBA(hex: "#00000080")?.alpha == 128.0 / 255)
        for bad in ["ff8000", "#ff80", "#gg8000", "#ff800000ff"] { #expect(RGBA(hex: bad) == nil) }
    }

    @Test func theBundledThemeResolvesEveryStyle() throws {
        let theme = try theme()
        #expect(theme.style("active").color == RGBA(hex: "#7aa2f7"))
        #expect(theme.style("active").font == FontToken(family: .monospaced, size: 12, weight: .bold))
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
        let props = StyleProps(padding: 4, fontSize: 20, background: "accent", color: "#ff0000")
        let resolved = theme.resolve("panel", props)
        #expect(resolved.padding == 4 && resolved.radius == 12)
        #expect(resolved.background == RGBA(hex: "#7aa2f7"))
        #expect(resolved.color == RGBA(hex: "#ff0000"))
        #expect(resolved.font == FontToken(family: .monospaced, size: 20, weight: .regular))
        #expect(theme.resolve(nil, props, hover: "hover").background == RGBA(hex: "#ffffff1a"))
        #expect(theme.resolve(nil, StyleProps(color: "no-such-color")).color == theme.style("default").color)
        #expect(theme.motion.fade == 0.15)
    }

    @Test func aStyleCanUseAHexLiteral() throws {
        #expect(try theme(##"{"styles": {"warn": {"color": "#ffcc00"}}}"##).style("warn").color == RGBA(hex: "#ffcc00"))
    }

    @Test func rejectsBrokenTokensWithTheirPath() {
        let cases: [(String, ThemeError)] = [
            (#"{"colors": {"accent": "blue"}}"#, ThemeError(path: "colors.accent", reason: "must be #rrggbb or #rrggbbaa")),
            (#"{"styles": {"active": {"color": "teal"}}}"#, ThemeError(path: "styles.active.color", reason: "unknown color teal")),
            (#"{"styles": {"active": {"font": "huge"}}}"#, ThemeError(path: "styles.active.font", reason: "unknown font huge")),
            (#"{"fonts": {"body": {"weight": "extra"}}}"#, ThemeError(path: "fonts.body.weight", reason: "unknown weight extra")),
            (#"{"bar": {"height": -1}}"#, ThemeError(path: "bar.height", reason: "must be a non-negative number")),
            (#"{"spacing": 8}"#, ThemeError(path: "spacing", reason: "must be an object")),
            (#"{"styles": {"panel": {"radius": -2}}}"#, ThemeError(path: "styles.panel.radius", reason: "must be a non-negative number")),
            (#"{"styles": {"panel": {"background": "fog"}}}"#, ThemeError(path: "styles.panel.background", reason: "unknown color fog")),
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
