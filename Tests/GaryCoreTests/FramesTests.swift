import GaryCore
import Testing

struct FramesTests {
    private func steady(_ count: Int, every interval: Double, from start: Double = 0) -> [Frame] {
        (0..<count).map { Frame(start: start + Double($0) * interval, end: start + Double($0 + 1) * interval, interval: interval) }
    }

    private func close(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 1e-9
    }

    @Test func `frames on time have no hitches`() {
        let summary = FrameSummary(steady(120, every: 1.0 / 120), spans: [])
        #expect(summary.frames == 120)
        #expect(close(summary.seconds, 1))
        #expect(summary.hitchRatio == 0)
        #expect(summary.hitches.isEmpty)
        #expect(close(summary.p50, 1.0 / 120) && close(summary.p99, 1.0 / 120) && close(summary.max, 1.0 / 120))
        #expect(summary.isSmooth)
    }

    @Test func `a late frame adds its time past the expected interval per second recorded`() {
        let interval = 0.01
        let late = Frame(start: 0.99, end: 1.03, interval: interval)
        let summary = FrameSummary(steady(99, every: interval) + [late], spans: [])
        #expect(summary.frames == 100)
        #expect(close(summary.seconds, 1.03))
        #expect(close(summary.hitchRatio, 30 / 1.03))
        #expect(summary.hitches.map(\.frame) == [late])
        #expect(late.missed == 3)
        #expect(close(summary.p50, interval) && close(summary.p99, interval) && close(summary.max, 0.04))
        #expect(!summary.isSmooth)
    }

    @Test func `the expected interval comes from the display's refresh rate`() {
        let frame = Frame(start: 0, end: 1.0 / 60, interval: 1.0 / 60)
        #expect(!frame.isLate)
        #expect(FrameSummary([frame], spans: []).hitchRatio == 0)
        #expect(Frame(start: 0, end: 1.0 / 60, interval: 1.0 / 120).isLate)
    }

    @Test func `a hitch lists the main-thread work inside it, and the unseen rest as other work`() throws {
        let hitch = Frame(start: 1, end: 1.04, interval: 0.01)
        let spans = [
            FrameSpan(.tree("you.menu/menu"), from: 0.99, to: 1.02),
            FrameSpan(.commit, from: 1.02, to: 1.025),
            FrameSpan(.asleep, from: 1.036, to: 1.05),
            FrameSpan(.layout, from: 1.05, to: 1.06),
        ]
        let causes = try #require(FrameSummary([hitch], spans: spans).hitches.first).causes
        #expect(causes.map(\.work) == [.tree("you.menu/menu"), .core, .commit, .asleep])
        #expect(zip(causes.map(\.seconds), [0.02, 0.011, 0.005, 0.004]).allSatisfy { close($0, $1) })
    }

    @Test func `the first frame after arming starts on the refresh before arming, so work at arming counts`() throws {
        let onTime = try #require(Frame.afterArming(1, shown: 1.006, interval: 0.01))
        #expect(!onTime.isLate)
        let jittered = try #require(Frame.afterArming(1, shown: 1.012, interval: 0.01))
        #expect(!jittered.isLate)
        let stalled = try #require(Frame.afterArming(1, shown: 1.031, interval: 0.01))
        #expect(close(stalled.duration, 0.03))
        #expect(stalled.missed == 2)
        #expect(Frame.afterArming(1, shown: 0.999, interval: 0.01) == nil)
    }

    @Test func `a 48 Hz idle run that the main thread sleeps through has no hitches`() {
        let interval = 1.0 / 120
        let frames = steady(48, every: 1.0 / 48).map { Frame(start: $0.start, end: $0.end, interval: interval) }
        let spans = frames.flatMap { [
            FrameSpan(.commit, from: $0.start, to: $0.start + 0.0002),
            FrameSpan(.asleep, from: $0.start + 0.0002, to: $0.end),
        ] }
        let summary = FrameSummary(frames, spans: spans)
        #expect(summary.hitches.isEmpty && summary.hitchRatio == 0)
        #expect(summary.idleGaps == 48 && summary.frames == 0)
        #expect(close(summary.seconds, 1))
        #expect(summary.isSmooth)
    }

    @Test func `a late frame counts when the main thread was busy at a refresh it missed, and an idle gap beside it does not`() throws {
        let interval = 1.0 / 120
        let idle = Frame(start: 0, end: 2.5 * interval, interval: interval)
        let busy = Frame(start: idle.end, end: idle.end + 2.5 * interval, interval: interval)
        let spans = [
            FrameSpan(.asleep, from: 0.0005, to: idle.end),
            FrameSpan(.asleep, from: busy.start, to: busy.start + 0.002),
            FrameSpan(.tree("you.menu/menu"), from: busy.start + 0.002, to: busy.start + 0.016),
            FrameSpan(.asleep, from: busy.start + 0.016, to: busy.end),
        ]
        let summary = FrameSummary([idle, busy], spans: spans)
        let hitch = try #require(summary.hitches.first)
        #expect(summary.hitches.count == 1 && hitch.frame == busy && summary.idleGaps == 1)
        #expect(hitch.causes.first?.work == .tree("you.menu/menu"))
        #expect(close(summary.hitchRatio, 1.5 * interval * 1000 / (5 * interval)))
        #expect(close(summary.max, busy.duration))
    }

    @Test func `a wakeup between refreshes does not make an idle gap a hitch`() {
        let interval = 1.0 / 120
        let frame = Frame(start: 0, end: 2.5 * interval, interval: interval)
        let spans = [FrameSpan(.asleep, from: 0, to: 0.01), FrameSpan(.asleep, from: 0.0105, to: frame.end)]
        let summary = FrameSummary([frame], spans: spans)
        #expect(summary.hitches.isEmpty && summary.idleGaps == 1)
    }

    @Test func `no frames summarize to zero`() {
        let summary = FrameSummary([], spans: [])
        #expect(summary.frames == 0 && summary.seconds == 0 && summary.hitchRatio == 0 && summary.max == 0)
        #expect(summary.isSmooth)
    }
}
