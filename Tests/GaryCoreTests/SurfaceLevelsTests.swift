import Foundation
@testable import GaryCore
import Testing

struct SurfaceLevelsTests {
    private func levels(_ major: Int, _ minor: Int, _ patch: Int = 0) -> SurfaceLevels {
        SurfaceLevels.forSystem(OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch))
    }

    @Test func `the bar clears the click strip from 27 point 2`() {
        #expect(levels(27, 2).bar == 26)
        #expect(levels(27, 2, 1).bar == 26)
        #expect(levels(28, 0).bar == 26)
        #expect(levels(27, 1, 9).bar == 25)
    }

    @Test func `every layer has A level and they stack in order`() {
        for version in [levels(27, 2), levels(26, 0)] {
            let stack = [SurfaceLayer.desktop, .below, .normal, .top].map(version.level)
            #expect(stack == stack.sorted())
            #expect(version.level(.notch) > version.bar)
            #expect(version.barAside < 24)
            #expect(version.level(.overlay) > version.level(.notch))
        }
        #expect(levels(27, 2).level(.overlay) == 101)
        #expect(levels(27, 2).level(.desktop) == -2_147_483_604)
    }
}
