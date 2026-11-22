import Foundation

public struct Gradient: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case linear, radial, angular
    }

    public var kind: Kind
    public var colors: [String]
    public var angle: Double

    public init(_ kind: Kind, colors: [String], angle: Double = 0) {
        self.kind = kind
        self.colors = colors
        self.angle = angle
    }
}

public enum Paint: Equatable, Sendable, ExpressibleByStringLiteral {
    case color(String)
    case gradient(Gradient)

    public static let syntax = "a colour, or { gradient: \"linear\", \"radial\" or \"angular\", colors: [two or more colours], angle?: degrees }"

    public init(stringLiteral value: String) {
        self = .color(value)
    }

    public var colors: [String] {
        switch self {
        case let .color(color): [color]
        case let .gradient(gradient): gradient.colors
        }
    }

    static func parse(_ value: JSON) -> Paint? {
        if let color = value.string {
            return ColorExpr(color) == nil ? nil : .color(color)
        }
        guard let fields = value.object, let kind = fields["gradient"]?.string.flatMap(Gradient.Kind.init(rawValue:)),
              let items = fields["colors"]?.array, items.count >= 2
        else { return nil }
        let colors = items.compactMap(\.string).filter { ColorExpr($0) != nil }
        let angle = fields["angle"] ?? .number(0)
        guard colors.count == items.count, let degrees = angle.number, degrees.isFinite else { return nil }
        return .gradient(Gradient(kind, colors: colors, angle: degrees))
    }
}

public enum ResolvedPaint: Equatable, Sendable {
    case color(RGBA)
    case gradient(Gradient.Kind, [RGBA], angle: Double)
}

public extension Theme {
    func paint(_ paint: Paint?) -> ResolvedPaint? {
        switch paint {
        case nil: return nil
        case let .color(reference)?: return color(reference).map(ResolvedPaint.color)
        case let .gradient(gradient)?:
            let colors = gradient.colors.compactMap(color)
            return colors.count == gradient.colors.count ? .gradient(gradient.kind, colors, angle: gradient.angle) : nil
        }
    }
}
