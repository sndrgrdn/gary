@testable import GaryCore
import Testing

struct SurfaceRouteTests {
    @Test func `a name goes to the first kind that declares it`() {
        #expect(SurfaceRoute.choose("osd", declared: [["main"], ["main", "osd"], ["osd"]]) == .show(1))
        #expect(SurfaceRoute.choose("main", declared: [["main"], ["main"]]) == .show(0))
    }

    @Test func `a kind whose names are unknown is shown directly when no later kind could declare the name`() {
        #expect(SurfaceRoute.choose("main", declared: [nil]) == .show(0))
        #expect(SurfaceRoute.choose("osd", declared: [["main"], nil]) == .show(1))
        #expect(SurfaceRoute.choose("osd", declared: [nil, ["main"]]) == .show(0))
    }

    @Test func `a kind whose names are unknown is loaded first when a later kind could declare the name`() {
        #expect(SurfaceRoute.choose("osd", declared: [nil, ["osd"]]) == .learn(0))
        #expect(SurfaceRoute.choose("osd", declared: [["main"], nil, nil]) == .learn(1))
    }

    @Test func `a name no kind declares is unknown`() {
        #expect(SurfaceRoute.choose("osd", declared: [["main"], ["menu"]]) == .unknown)
        #expect(SurfaceRoute.choose("osd", declared: []) == .unknown)
    }
}
