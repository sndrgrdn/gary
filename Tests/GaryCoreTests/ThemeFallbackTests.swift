import Foundation
@testable import GaryCore
import Testing

struct ThemeFallbackTests {
    private func theme(_ override: String? = nil) throws -> Theme {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/theme.json")
        return try Theme.parse(
            JSON.parse(Data(contentsOf: bundled)),
            override: override.map { try JSON.parse($0) },
            palette: Palette(nil, system: .dark),
        )
    }

    @Test func `an unknown font in node properties falls back to the default font of the surface or the bar`() throws {
        let theme = try theme(#"{"bar":{"fonts":{"body":{"family":"Menlo","size":11}}}}"#)
        let unknown = StyleProps(font: "no-such-font")
        #expect(theme.resolve(nil, unknown).font == theme.style("default").font)
        #expect(theme.inBar.resolve(nil, unknown).font == FontToken(family: .named("Menlo"), size: 11, weight: .regular))
    }

    @Test func `the default style must exist and name a colour and a font`() throws {
        let cases: [(String, ThemeError)] = [
            (#"{"styles": {"default": 3}}"#, ThemeError(path: "styles.default", reason: "must be an object")),
            (#"{"styles": {"default": {"color": null}}}"#, ThemeError(path: "styles.default.color", reason: "must name a color")),
            (#"{"styles": {"default": {"font": null}}}"#, ThemeError(path: "styles.default.font", reason: "must name a font")),
        ]
        for (override, error) in cases {
            #expect(throws: error, "\(override)") { try theme(override) }
        }
    }
}
