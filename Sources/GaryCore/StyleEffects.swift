import Foundation

public enum Blend: String, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, plusLighter, plusDarker, difference
}

public struct Loop: Equatable, Sendable {
    public enum Property: String, CaseIterable, Sendable {
        case opacity, scale, rotation, x, y
    }

    public struct Span: Equatable, Sendable {
        public var from: Double
        public var to: Double

        public init(_ from: Double, _ to: Double) {
            self.from = from
            self.to = to
        }

        public func at(_ phase: Double) -> Double {
            from + (to - from) * phase
        }
    }

    public static let syntax = "an object with [from, to] for any of " + Property.allCases.map(\.rawValue).joined(separator: ", ")
        + ", and duration and reverse"

    public var spans: [Property: Span]
    public var duration: Double
    public var reverse: Bool

    public init(_ spans: [Property: Span], duration: Double = 1, reverse: Bool = false) {
        self.spans = spans
        self.duration = duration
        self.reverse = reverse
    }

    public func phase(after elapsed: Double) -> Double {
        let cycles = max(0, elapsed) / duration
        guard reverse else { return cycles.truncatingRemainder(dividingBy: 1) }
        let leg = cycles.truncatingRemainder(dividingBy: 2)
        let linear = leg <= 1 ? leg : 2 - leg
        return linear * linear * (3 - 2 * linear)
    }
}
