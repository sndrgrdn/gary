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

    @Test func `clamps numbers outside their range to its nearest end`() throws {
        #expect(
            try parse(
                #"{"opacity": 1.5, "width": -4, "scale": -1, "duration": -0.1, "padding": [-2, 6], "shadow": {"color": "accent", "radius": -1}}"#,
            )
                == StyleProps(
                    width: 0,
                    padding: Insets(top: 0, right: 6, bottom: 0, left: 6),
                    opacity: 1,
                    scale: 0,
                    duration: 0,
                    shadow: Shadow(color: "accent", radius: 0),
                ),
        )
        #expect(try parse(#"{"loop": {"opacity": [-1, 2]}}"#).loop == Loop([.opacity: Loop.Span(0, 1)]))
    }

    @Test func `rejects a font that is not a name a colour that does not parse and a malformed padding`() {
        let cases: [(String, Failure)] = [
            (#"{"font": 12}"#, Failure(field: "font", reason: "must name a theme font")),
            (#"{"color": "mix(a"}"#, Failure(field: "color", reason: "must be \(ColorExpr.syntax)")),
            (#"{"padding": [1, 2, 3]}"#, Failure(field: "padding", reason: "must be \(Insets.syntax)")),
        ]
        for (text, failure) in cases {
            #expect(throws: failure, "\(text)") { try parse(text) }
        }
    }
}

struct DrawingStylePropsTests {
    private struct Failure: Error, Equatable {
        let field: String
        let reason: String
    }

    private func parse(_ text: String) throws -> StyleProps {
        try StyleProps.parse(#require(JSON.parse(text).object)) { field, reason in Failure(field: field, reason: reason) }
    }

    @Test func `reads rotation blur blend and a loop with its defaults`() throws {
        #expect(try parse(#"{"rotation": -45, "blur": 2, "blend": "plusLighter"}"#) == StyleProps(rotation: -45, blur: 2, blend: .plusLighter))
        #expect(try parse(#"{"loop": {"rotation": [0, 360]}}"#).loop == Loop([.rotation: Loop.Span(0, 360)]))
        #expect(try parse(#"{"loop": {"opacity": [0.2, 1], "x": [-4, 4], "duration": 0.5, "reverse": true}}"#).loop
            == Loop([.opacity: Loop.Span(0.2, 1), .x: Loop.Span(-4, 4)], duration: 0.5, reverse: true))
    }

    @Test func `rejects a blur that is not a number an unknown blend and a malformed loop`() {
        let cases: [(String, Failure)] = [
            (#"{"blur": "soft"}"#, Failure(field: "blur", reason: "must be a number")),
            (#"{"rotation": "90"}"#, Failure(field: "rotation", reason: "must be a number")),
            (#"{"blend": "lighten"}"#, Failure(
                field: "blend",
                reason: "must be one of " + Blend.allCases.map { "\"\($0.rawValue)\"" }
                    .joined(separator: ", "),
            )),
            (#"{"loop": 1}"#, Failure(field: "loop", reason: "must be \(Loop.syntax)")),
            (#"{"loop": {"scale": [1]}}"#, Failure(field: "loop.scale", reason: "must be [from, to]")),
            (#"{"loop": {"opacity": [0]}}"#, Failure(field: "loop.opacity", reason: "must be [from, to]")),
            (#"{"loop": {"duration": 0}}"#, Failure(field: "loop.duration", reason: "must be a positive number")),
            (#"{"loop": {"reverse": 1}}"#, Failure(field: "loop.reverse", reason: "must be true or false")),
        ]
        for (text, failure) in cases {
            #expect(throws: failure, "\(text)") { try parse(text) }
        }
    }

    @Test func `a hovered loop blend rotation and gradient override the base`() {
        let base = StyleProps(background: "panel", rotation: 10, blend: .multiply)
        let hovered = StyleProps(background: .gradient(Gradient(.linear, colors: ["a", "b"])), loop: Loop([.scale: Loop.Span(1, 1.1)]))
        #expect(hovered.over(base) == StyleProps(
            background: .gradient(Gradient(.linear, colors: ["a", "b"])),
            rotation: 10,
            blend: .multiply,
            loop: Loop([.scale: Loop.Span(1, 1.1)]),
        ))
        #expect(StyleProps().over(base) == base)
    }
}

struct LoopPhaseTests {
    @Test func `a loop runs from zero to one over its duration and starts again`() {
        let loop = Loop([.rotation: Loop.Span(0, 360)], duration: 2)
        #expect(loop.phase(after: 0) == 0)
        #expect(loop.phase(after: 1) == 0.5)
        #expect(loop.phase(after: 3) == 0.5)
        #expect(loop.spans[.rotation]?.at(loop.phase(after: 1.5)) == 270)
    }

    @Test func `a reversed loop eases there and back over two durations`() {
        let loop = Loop([.opacity: Loop.Span(0.2, 1)], reverse: true)
        #expect(loop.phase(after: 0) == 0)
        #expect(loop.phase(after: 0.5) == 0.5)
        #expect(loop.phase(after: 1) == 1)
        #expect(loop.phase(after: 1.5) == 0.5)
        #expect(loop.phase(after: 2) == 0)
        #expect(loop.phase(after: 0.25) < 0.25)
    }
}
