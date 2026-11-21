import Foundation
import Testing
@testable import GaryCore

struct SurfaceLevelsTests {
    private func levels(_ major: Int, _ minor: Int, _ patch: Int = 0) -> SurfaceLevels {
        SurfaceLevels.forSystem(OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch))
    }

    @Test func theBarClearsTheClickStripFrom27Point2() {
        #expect(levels(27, 2).bar == 26)
        #expect(levels(27, 2, 1).bar == 26)
        #expect(levels(28, 0).bar == 26)
        #expect(levels(27, 1, 9).bar == 25)
        #expect(levels(27, 2).panel == 101)
    }
}
