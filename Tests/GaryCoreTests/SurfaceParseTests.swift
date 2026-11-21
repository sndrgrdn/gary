@testable import GaryCore
import Testing

struct SurfaceParseTests {
    private func spec(_ text: String) throws -> SurfaceSpec {
        try SurfaceSpec.parse(JSON.parse(text), kind: .panel)
    }

    @Test func `margins take one number for every side or an object of sides`() throws {
        #expect(try spec(#"{"margins":6}"#).margins == Edges(top: 6, bottom: 6, left: 6, right: 6))
        #expect(try spec(#"{"margins":{"right":3}}"#).margins == Edges(top: 0, bottom: 0, left: 0, right: 3))
    }

    @Test func `rejects the remaining malformed fields with their path`() {
        let cases: [(String, SurfaceError)] = [
            (#"{"exclusionMode":"push"}"#, SurfaceError(path: "surface.exclusionMode", reason: "must be \"normal\" or \"ignore\"")),
            (#"{"anchors":true}"#, SurfaceError(path: "surface.anchors", reason: "must be an object with top, bottom, left and right")),
            (#"{"screen":64}"#, SurfaceError(path: "surface.screen", reason: "must be \"main\", \"focused\", \"all\" or a display index")),
            (#"{"focusable":"yes"}"#, SurfaceError(path: "surface.focusable", reason: "must be true or false")),
            (#"{"height":0}"#, SurfaceError(path: "surface.height", reason: "must be a positive number or \"fit\"")),
            (#"{"margins":-2}"#, SurfaceError(path: "surface.margins", reason: "must be a non-negative number")),
            (#"{"clickThrough":1,"anchors":2}"#, SurfaceError(path: "surface.anchors", reason: "must be an object with top, bottom, left and right")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try spec(text) }
        }
    }
}
