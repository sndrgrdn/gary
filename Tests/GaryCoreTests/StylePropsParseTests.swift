@testable import GaryCore
import Testing

struct StylePropsParseTests {
    private struct Failure: Error, Equatable {
        let field: String
        let reason: String
    }

    private func parse(_ text: String) throws -> StyleProps {
        try StyleProps.parse(#require(JSON.parse(text).object)) { field, reason in Failure(field: field, reason: reason) }
    }

    @Test func `null fields count as absent`() throws {
        let fields = ["width", "x", "padding", "align", "clip", "shadow", "border", "background", "font"]
        #expect(try parse("{" + fields.map { "\"\($0)\": null" }.joined(separator: ",") + "}") == StyleProps())
    }

    @Test func `reads colours fonts and clipping`() throws {
        #expect(try parse(#"{"background": "accent", "color": "mix(fg, bg, 0.5)", "font": "title", "clip": false, "opacity": 1}"#)
            == StyleProps(opacity: 1, background: "accent", color: "mix(fg, bg, 0.5)", font: "title", clip: false))
    }

    @Test func `rejects an opacity above one a font that is not a name and a colour that does not parse`() {
        let cases: [(String, Failure)] = [
            (#"{"opacity": 1.5}"#, Failure(field: "opacity", reason: "must be between 0 and 1")),
            (#"{"font": 12}"#, Failure(field: "font", reason: "must name a theme font")),
            (#"{"color": "mix(a"}"#, Failure(field: "color", reason: "must be \(ColorExpr.syntax)")),
            (#"{"padding": [1, 2, 3]}"#, Failure(field: "padding", reason: "must be \(Insets.syntax)")),
        ]
        for (text, failure) in cases {
            #expect(throws: failure, "\(text)") { try parse(text) }
        }
    }
}
