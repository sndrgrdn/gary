import CoreGraphics
import Foundation
@testable import GaryCore
import Testing

private final class FakeSurface {
    var display: DisplayInfo
    var updates = 0
    var closed = false

    init(_ display: DisplayInfo) { self.display = display }
}

private struct Harness {
    var bars = PerDisplay<FakeSurface>()
    var opened: [FakeSurface] = []

    @discardableResult
    mutating func show(_ screens: [DisplayInfo]) -> DisplayChange {
        var opened = self.opened
        let change = bars.sync(screens, open: { display in
            let surface = FakeSurface(display)
            opened.append(surface)
            return surface
        }, update: { surface, display in
            surface.display = display
            surface.updates += 1
        }, close: { $0.closed = true })
        self.opened = opened
        return change
    }

    var live: [FakeSurface] { opened.filter { !$0.closed } }
}

private func screen(_ id: String, _ index: Int, x: Double = 0, width: Double = 1512, height: Double = 982, notch: Bool = false) -> DisplayInfo {
    DisplayInfo(id: id, index: index, frame: CGRect(x: x, y: 0, width: width, height: height), band: notch ? 32 : 28, notch: notch ? 660...852 : nil)
}

private let builtIn = screen("built-in", 0, notch: true)
private let left = screen("left", 1, x: -1920, width: 1920, height: 1080)
private let right = screen("right", 2, x: 1512, width: 2560, height: 1440)

private func expectOneSurfacePerScreen(_ harness: Harness, _ screens: [DisplayInfo], sourceLocation: SourceLocation = #_sourceLocation) {
    let live = harness.live
    #expect(live.count == screens.count, sourceLocation: sourceLocation)
    #expect(Set(live.map(\.display.id)) == Set(screens.map(\.id)), sourceLocation: sourceLocation)
    for display in screens {
        #expect(harness.bars[display.id]?.display == display, sourceLocation: sourceLocation)
        #expect(harness.bars[display.id]?.closed == false, sourceLocation: sourceLocation)
    }
}

struct PerDisplayTests {
    @Test func plugsAndUnplugsScreensWithoutLeaksOrDuplicates() {
        var harness = Harness()
        let steps: [[DisplayInfo]] = [
            [builtIn],
            [builtIn, left],
            [builtIn, left, right],
            [builtIn, right].enumerated().map { var s = $1; s.index = $0; return s },
            [builtIn],
            [],
            [builtIn, left],
        ]
        for screens in steps {
            harness.show(screens)
            expectOneSurfacePerScreen(harness, screens)
        }
        #expect(harness.opened.count == 5)
    }

    @Test func reorderingAndResizingUpdateTheSameSurfaces() {
        var harness = Harness()
        harness.show([builtIn, left])
        let first = harness.opened

        var main = left
        main.index = 0
        var second = builtIn
        second.index = 1
        let reorder = harness.show([main, second])
        #expect(reorder.changed == ["left", "built-in"])
        #expect(reorder.added.isEmpty && reorder.removed.isEmpty)
        expectOneSurfacePerScreen(harness, [main, second])

        var bigger = main
        bigger.frame.size = CGSize(width: 3840, height: 2160)
        let resize = harness.show([bigger, second])
        #expect(resize.changed == ["left"])
        expectOneSurfacePerScreen(harness, [bigger, second])
        #expect(harness.opened.map(ObjectIdentifier.init) == first.map(ObjectIdentifier.init))
        #expect(harness.bars["left"]?.updates == 2)
        #expect(harness.bars["built-in"]?.updates == 1)
    }

    @Test func anUnchangedSetTouchesNothing() {
        var harness = Harness()
        harness.show([builtIn, left])
        let change = harness.show([builtIn, left])
        #expect(change.isEmpty)
        #expect(harness.opened.count == 2)
        #expect(harness.live.allSatisfy { $0.updates == 0 })
    }

    @Test func sleepThatDropsEveryScreenRestoresThemOnWake() {
        var harness = Harness()
        harness.show([builtIn, right])
        let sleep = harness.show([])
        #expect(Set(sleep.removed) == ["built-in", "right"])
        #expect(harness.live.isEmpty)
        let wake = harness.show([builtIn, right])
        #expect(wake.added == ["built-in", "right"])
        expectOneSurfacePerScreen(harness, [builtIn, right])
    }

    @Test func aRepeatedIDGetsOneSurface() {
        var harness = Harness()
        var twin = builtIn
        twin.index = 1
        harness.show([builtIn, twin])
        #expect(harness.opened.count == 1)
        expectOneSurfacePerScreen(harness, [builtIn])
    }

    @Test func randomHotPlugSequencesKeepOneSurfacePerScreen() {
        var random = SeededRandom(seed: 42)
        var harness = Harness()
        let pool = [builtIn, left, right, screen("tv", 3, x: 4072, width: 1280, height: 720), screen("ipad", 4, x: 0, width: 1366, height: 1024)]
        for _ in 0..<2000 {
            var screens = pool.filter { _ in random.next(2) == 0 }
            for index in screens.indices.reversed() { screens.swapAt(index, random.next(index + 1)) }
            for index in screens.indices {
                screens[index].index = index
                if random.next(4) == 0 { screens[index].frame.size.width = Double(800 + random.next(3000)) }
            }
            let before = Dictionary(uniqueKeysWithValues: harness.live.map { ($0.display.id, ObjectIdentifier($0)) })
            let change = harness.show(screens)
            expectOneSurfacePerScreen(harness, screens)
            for display in screens where !change.added.contains(display.id) {
                #expect(before[display.id] == harness.bars[display.id].map(ObjectIdentifier.init))
            }
        }
    }
}

struct DisplayChangeTests {
    @Test func namesAddedRemovedAndChangedScreens() {
        var moved = left
        moved.frame.origin.x = 1512
        let change = DisplayChange(from: [builtIn, left, right], to: [builtIn, moved, screen("tv", 2)])
        #expect(change.added == ["tv"])
        #expect(change.removed == ["right"])
        #expect(change.changed == ["left"])
    }
}
