import Foundation
@testable import GaryCore
import Testing

struct PaintTests {
    private struct Failure: Error, Equatable {
        let field: String
        let reason: String
    }

    private func background(_ text: String) throws -> Paint? {
        try StyleProps.parse(#require(JSON.parse(#"{"background": \#(text)}"#).object)) { field, reason in
            Failure(field: field, reason: reason)
        }.background
    }

    private func theme(_ override: String) throws -> Theme {
        let bundled = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json")))
        return try Theme.parse(bundled, palette: Palette(nil, system: .dark), override: JSON.parse(override))
    }

    @Test func `a background is a colour expression or a gradient of two or more colours`() throws {
        #expect(try background("\"alpha(accent, 0.5)\"") == .color("alpha(accent, 0.5)"))
        #expect(try background(##"{"gradient": "linear", "colors": ["accent", "#ff0000"], "angle": 90}"##)
            == .gradient(Gradient(.linear, colors: ["accent", "#ff0000"], angle: 90)))
        #expect(try background(#"{"gradient": "angular", "colors": ["a", "b", "c"]}"#) == .gradient(Gradient(.angular, colors: ["a", "b", "c"])))
    }

    @Test(arguments: [
        #"{"gradient": "linear", "colors": ["accent"]}"#,
        #"{"gradient": "conic", "colors": ["a", "b"]}"#,
        #"{"gradient": "radial", "colors": ["a", "mix(a"]}"#,
        #"{"gradient": "radial", "colors": ["a", "b"], "angle": "up"}"#,
        #"{"colors": ["a", "b"]}"#,
        "\"mix(a\"",
        "12",
    ])
    func `rejects a paint that is not a colour or a gradient`(_ text: String) {
        #expect(throws: Failure(field: "background", reason: "must be \(Paint.syntax)")) { try background(text) }
    }

    @Test func `the theme resolves each gradient colour and drops a gradient with a colour it cannot resolve`() throws {
        let theme = try theme(##"{"colors": {"accent": "#ff0000"}}"##)
        #expect(theme.paint(.gradient(Gradient(.radial, colors: ["accent", "#0000ff"])))
            == .gradient(.radial, [RGBA(red: 1, green: 0, blue: 0), RGBA(red: 0, green: 0, blue: 1)], angle: 0))
        #expect(theme.paint(.gradient(Gradient(.linear, colors: ["accent", "fog"]))) == nil)
        #expect(theme.paint("accent") == .color(RGBA(red: 1, green: 0, blue: 0)))
    }

    @Test func `a theme style takes a gradient background and warns about its unknown colours`() throws {
        let theme = try theme(#"{"styles": {"panel": {"background": {"gradient": "linear", "colors": ["accent", "fog"]}}}}"#)
        #expect(theme.styles["panel"]?.background == .gradient(Gradient(.linear, colors: ["accent", "fog"])))
        #expect(theme.warnings == ["styles.panel.background: no colour fog with this palette"])
        #expect(theme.style("panel").background == nil)
    }
}
