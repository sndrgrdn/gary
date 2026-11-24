import Foundation

public enum FrameWork: Hashable, Sendable {
    case tree(String)
    case layout, draw, decode, commit, core, asleep

    public var label: String {
        switch self {
        case let .tree(slot): "tree \(slot)"
        case .layout: "layout"
        case .draw: "draw"
        case .decode: "image decode"
        case .commit: "Core Animation commit"
        case .core: "other main-thread work"
        case .asleep: "main thread asleep"
        }
    }
}

public struct FrameSpan: Equatable, Sendable {
    public let work: FrameWork
    public let start: Double
    public let end: Double

    public init(_ work: FrameWork, from start: Double, to end: Double) {
        self.work = work
        self.start = start
        self.end = end
    }
}

public struct Frame: Equatable, Sendable {
    public static let kept: TimeInterval = 60

    public let start: Double
    public let end: Double
    public let interval: Double

    public init(start: Double, end: Double, interval: Double) {
        self.start = start
        self.end = end
        self.interval = interval
    }

    public static func afterArming(_ armed: Double, shown: Double, interval: Double) -> Frame? {
        guard shown > armed, interval > 0 else { return nil }
        let frames = max(1, ((shown - armed) / interval - 0.25).rounded(.up))
        return Frame(start: shown - frames * interval, end: shown, interval: interval)
    }

    public var duration: Double {
        end - start
    }

    public var isHitch: Bool {
        duration > interval * 1.5
    }

    public var missed: Int {
        isHitch ? Int((duration / interval).rounded()) - 1 : 0
    }
}

public struct FrameSummary: Equatable, Sendable {
    public struct Cause: Equatable, Sendable {
        public let work: FrameWork
        public let seconds: Double
    }

    public struct Hitch: Equatable, Sendable {
        public let frame: Frame
        public let causes: [Cause]
    }

    public static let smoothHitchRatio = 5.0

    public let frames: Int
    public let seconds: Double
    public let hitchRatio: Double
    public let p50: Double
    public let p99: Double
    public let max: Double
    public let hitches: [Hitch]

    public init(_ frames: [Frame], spans: [FrameSpan]) {
        let durations = frames.map(\.duration).sorted()
        self.frames = frames.count
        seconds = durations.reduce(0, +)
        let hitchTime = frames.filter(\.isHitch).map { $0.duration - $0.interval }.reduce(0, +)
        hitchRatio = seconds > 0 ? hitchTime * 1000 / seconds : 0
        p50 = Self.percentile(durations, 0.5)
        p99 = Self.percentile(durations, 0.99)
        max = durations.last ?? 0
        hitches = frames.filter(\.isHitch).map { Hitch(frame: $0, causes: Self.causes(of: $0, spans)) }
    }

    public var isSmooth: Bool {
        hitchRatio < Self.smoothHitchRatio
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count, rank) - 1)]
    }

    private static func causes(of frame: Frame, _ spans: [FrameSpan]) -> [Cause] {
        var seconds: [FrameWork: Double] = [:]
        for span in spans where span.end > frame.start && span.start < frame.end {
            seconds[span.work, default: 0] += Swift.min(span.end, frame.end) - Swift.max(span.start, frame.start)
        }
        seconds[.core, default: 0] += Swift.max(0, frame.duration - seconds.values.reduce(0, +))
        return seconds.filter { $0.value >= 0.0001 }.map { Cause(work: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.work.label < $1.work.label }
    }
}
