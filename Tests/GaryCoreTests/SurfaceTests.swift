import Foundation
import Testing
@testable import GaryCore

struct SurfaceTests {
    private let display = DisplayInfo(id: "a", index: 0, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), band: 32)
    private let content = CGSize(width: 200, height: 100)

    private func spec(_ text: String, kind: PluginKind = .panel) throws -> SurfaceSpec {
        try SurfaceSpec.parse(try JSON.parse(text), kind: kind)
    }

    private func frame(_ text: String, kind: PluginKind = .panel, content: CGSize? = nil) throws -> CGRect {
        let content = content ?? self.content
        return try spec(text, kind: kind).frame(on: display) { width, height, _ in
            CGSize(width: width ?? content.width, height: height ?? content.height)
        }
    }

    @Test func noAnchorsCentresTheContentBelowTheBarBand() throws {
        #expect(try frame("{}") == CGRect(x: 400, y: 334, width: 200, height: 100))
    }

    @Test func oneAnchorPinsThatEdgeWithItsMargin() throws {
        #expect(try frame(#"{"anchors":{"top":true,"right":true},"margins":{"top":8,"right":16}}"#)
            == CGRect(x: 784, y: 800 - 32 - 8 - 100, width: 200, height: 100))
        #expect(try frame(#"{"anchors":{"bottom":true},"margins":80}"#) == CGRect(x: 400, y: 80, width: 200, height: 100))
        #expect(try frame(#"{"anchors":{"left":true},"margins":{"left":10}}"#) == CGRect(x: 10, y: 334, width: 200, height: 100))
    }

    @Test func opposingAnchorsStretchBetweenTheMargins() throws {
        #expect(try frame(#"{"anchors":{"left":true,"right":true,"top":true},"margins":{"left":10,"right":20},"height":40}"#)
            == CGRect(x: 10, y: 800 - 32 - 40, width: 970, height: 40))
    }

    @Test func anOverlayCoversTheWholeScreenByDefault() throws {
        #expect(try frame("{}", kind: .overlay) == CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(try frame(#"{"exclusionMode":"normal"}"#, kind: .overlay) == CGRect(x: 0, y: 0, width: 1000, height: 768))
    }

    @Test func fixedSizesSkipFittingAndFitAsksOnlyForTheFreeAxis() throws {
        var asked: [(Double?, Double?)] = []
        let fixed = try spec(#"{"width":300,"height":50}"#).frame(on: display) { width, height, _ in
            asked.append((width, height))
            return .zero
        }
        #expect(fixed.size == CGSize(width: 300, height: 50))
        #expect(asked.isEmpty)
        _ = try spec(#"{"width":300}"#).frame(on: display) { width, height, _ in
            asked.append((width, height))
            return CGSize(width: 300, height: 70)
        }
        #expect(asked.count == 1 && asked[0].0 == 300 && asked[0].1 == nil)
    }

    @Test func aSurfaceStaysOnItsScreenWhenItsContentOutgrowsIt() throws {
        let wide = CGSize(width: 1400, height: 100)
        #expect(try frame(#"{"anchors":{"top":true,"right":true},"margins":{"top":8,"right":16}}"#, content: wide)
            == CGRect(x: 0, y: 800 - 32 - 8 - 100, width: 984, height: 100))
        #expect(try frame("{}", content: CGSize(width: 1200, height: 900)) == CGRect(x: 0, y: 0, width: 1000, height: 768))
        #expect(try frame(#"{"width":1500,"anchors":{"left":true},"margins":{"left":10}}"#) == CGRect(x: 10, y: 334, width: 990, height: 100))
    }

    @Test func fittingIsToldTheSpaceLeftOnTheScreen() throws {
        var limits: [CGSize] = []
        _ = try spec(#"{"anchors":{"top":true,"right":true},"margins":{"top":8,"right":16,"left":50}}"#).frame(on: display) { _, _, limit in
            limits.append(limit)
            return content
        }
        #expect(limits == [CGSize(width: 984, height: 760)])
    }

    @Test func kindsHaveTheirOwnDefaults() {
        #expect(SurfaceSpec.defaults(for: .menu).focusable)
        #expect(SurfaceSpec.defaults(for: .menu).layer == .overlay)
        #expect(!SurfaceSpec.defaults(for: .panel).focusable)
        #expect(SurfaceSpec.defaults(for: .panel).layer == .top)
        #expect(SurfaceSpec.defaults(for: .overlay).anchors == SurfaceSpec.all)
    }

    @Test func parsesEveryField() throws {
        let parsed = try spec(#"{"screen":"all","anchors":{"bottom":true},"width":"fit","height":24,"margins":{"bottom":4},"layer":"notch","exclusionMode":"ignore","clickThrough":true,"focusable":true}"#)
        #expect(parsed.screen == .all)
        #expect(parsed.anchors == Edges(top: false, bottom: true, left: false, right: false))
        #expect(parsed.width == .fit && parsed.height == .points(24))
        #expect(parsed.margins == Edges(top: 0, bottom: 4, left: 0, right: 0))
        #expect(parsed.layer == .notch && parsed.exclusionMode == .ignore && parsed.clickThrough && parsed.focusable)
        #expect(try spec(#"{"screen":1}"#).screen == .index(1))
        #expect(try spec("null") == SurfaceSpec.defaults(for: .panel))
    }

    @Test func rejectsMalformedSurfacesWithTheirPath() {
        let cases: [(String, SurfaceError)] = [
            ("[]", SurfaceError(path: "surface", reason: "must be an object")),
            (#"{"screen":"left"}"#, SurfaceError(path: "surface.screen", reason: "must be \"main\", \"focused\", \"all\" or a display index")),
            (#"{"anchors":{"middle":true}}"#, SurfaceError(path: "surface.anchors.middle", reason: "is not top, bottom, left or right")),
            (#"{"anchors":{"top":1}}"#, SurfaceError(path: "surface.anchors.top", reason: "must be true or false")),
            (#"{"width":-3}"#, SurfaceError(path: "surface.width", reason: "must be a positive number or \"fit\"")),
            (#"{"margins":{"left":-1}}"#, SurfaceError(path: "surface.margins.left", reason: "must be a non-negative number")),
            (#"{"layer":"floating"}"#, SurfaceError(path: "surface.layer", reason: "must be one of desktop, below, normal, top, overlay, notch")),
            (#"{"anchor":{}}"#, SurfaceError(path: "surface.anchor", reason: "is not a surface field")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try spec(text) }
        }
    }

    @Test func screensSelectByNameOrIndexAndFallBackToTheMainDisplay() {
        let displays = (0..<3).map { DisplayInfo(id: "d\($0)", index: $0, frame: .zero, band: 0) }
        #expect(ScreenSelector.all.select(displays, focused: nil).map(\.id) == ["d0", "d1", "d2"])
        #expect(ScreenSelector.main.select(displays, focused: "d2").map(\.id) == ["d0"])
        #expect(ScreenSelector.focused.select(displays, focused: "d2").map(\.id) == ["d2"])
        #expect(ScreenSelector.focused.select(displays, focused: "gone").map(\.id) == ["d0"])
        #expect(ScreenSelector.index(1).select(displays, focused: nil).map(\.id) == ["d1"])
        #expect(ScreenSelector.index(5).select(displays, focused: nil).map(\.id) == ["d0"])
        #expect(ScreenSelector.all.select([], focused: nil).isEmpty)
    }
}
