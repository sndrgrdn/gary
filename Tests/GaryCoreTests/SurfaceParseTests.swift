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
            (#"{"attach":"below"}"#, SurfaceError(path: "surface.attach", reason: "must be true or false")),
            (#"{"height":0}"#, SurfaceError(path: "surface.height", reason: "must be a positive number or \"fit\"")),
            (#"{"margins":-2}"#, SurfaceError(path: "surface.margins", reason: "must be a non-negative number")),
            (#"{"clickThrough":1,"anchors":2}"#, SurfaceError(path: "surface.anchors", reason: "must be an object with top, bottom, left and right")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try spec(text) }
        }
    }

    private func surfaces(_ text: String) throws -> [String: SurfaceSpec] {
        try SurfaceSpec.parseAll(JSON.parse(text), kind: .panel)
    }

    @Test func `a module with surface or no surface has one surface named main`() throws {
        #expect(try surfaces(#"{"surface":{"width":300}}"#).mapValues(\.width) == ["main": .points(300)])
        #expect(try surfaces("{}") == ["main": SurfaceSpec.defaults(for: .panel)])
    }

    @Test func `surfaces maps each name to its own surface`() throws {
        let specs = try surfaces(#"{"surfaces":{"main":{"attach":true},"volume-2":null}}"#)
        #expect(specs.keys.sorted() == ["main", "volume-2"])
        #expect(specs["main"]?.attach == true)
        #expect(specs["volume-2"] == SurfaceSpec.defaults(for: .panel))
    }

    @Test func `rejects surface with surfaces, bad names and bad fields with their path`() {
        let cases: [(String, SurfaceError)] = [
            (
                #"{"surface":{},"surfaces":{"osd":{}}}"#,
                SurfaceError(path: "surfaces", reason: "cannot be exported with surface; put that surface in surfaces as main"),
            ),
            (#"{"surfaces":{}}"#, SurfaceError(path: "surfaces", reason: "must be an object of one or more named surfaces")),
            (#"{"surfaces":[{}]}"#, SurfaceError(path: "surfaces", reason: "must be an object of one or more named surfaces")),
            (
                #"{"surfaces":{"Osd":{}}}"#,
                SurfaceError(path: "surfaces.Osd", reason: "is not a surface name; use lowercase letters, digits and hyphens"),
            ),
            (#"{"surfaces":{"":{}}}"#, SurfaceError(path: "surfaces.", reason: "is not a surface name; use lowercase letters, digits and hyphens")),
            (
                #"{"surfaces":{"osd":{"layer":"top","width":-1}}}"#,
                SurfaceError(path: "surfaces.osd.width", reason: "must be a positive number or \"fit\""),
            ),
            (#"{"surfaces":{"osd":3}}"#, SurfaceError(path: "surfaces.osd", reason: "must be an object")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try surfaces(text) }
        }
    }

    @Test func `a surface address is a plugin id with an optional surface name`() throws {
        let id = try #require(PluginID("you.music"))
        #expect(SurfaceAddress("you.music") == SurfaceAddress(id))
        #expect(SurfaceAddress("you.music:osd") == SurfaceAddress(id, surface: "osd"))
        #expect(SurfaceAddress("you.music:osd")?.description == "you.music:osd")
        #expect(SurfaceAddress("you.music:main")?.description == "you.music")
        for text in ["you.music:", "you.music:OSD", "you.music:a b", "you.music:osd:x", "music:osd"] {
            #expect(SurfaceAddress(text) == nil, "\(text)")
        }
    }
}
