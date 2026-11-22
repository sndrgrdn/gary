@testable import GaryCore
import Testing

struct SurfaceLevelsTests {
    @Test func `every layer has A level and they stack in order`() {
        let stack = [SurfaceLayer.desktop, .below, .normal, .top].map(SurfaceLevels.level)
        #expect(stack == stack.sorted())
        #expect(SurfaceLevels.bar == 26)
        #expect(SurfaceLevels.level(.notch) > SurfaceLevels.bar)
        #expect(SurfaceLevels.barAside < 24)
        #expect(SurfaceLevels.level(.overlay) > SurfaceLevels.level(.notch))
        #expect(SurfaceLevels.level(.overlay) == 101)
        #expect(SurfaceLevels.level(.desktop) == -2_147_483_604)
    }
}
