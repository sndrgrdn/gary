import Foundation

public struct Insets: Equatable, Sendable {
    public var top, right, bottom, left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(_ all: Double) {
        self.init(top: all, right: all, bottom: all, left: all)
    }

    public static let syntax = "a non-negative number, [vertical, horizontal], or [top, right, bottom, left]"

    static func parse(_ value: JSON) -> Insets? {
        let sides = value.array ?? [value]
        let numbers = sides.compactMap(\.number)
        guard numbers.count == sides.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        switch numbers.count {
        case 1: return Insets(numbers[0])
        case 2: return Insets(top: numbers[0], right: numbers[1], bottom: numbers[0], left: numbers[1])
        case 4: return Insets(top: numbers[0], right: numbers[1], bottom: numbers[2], left: numbers[3])
        default: return nil
        }
    }
}

public enum Align: String, CaseIterable, Sendable {
    case leading, center, trailing
}

public enum Animation: String, CaseIterable, Sendable {
    case smooth, spring, none
}

public enum Material: String, CaseIterable, Sendable {
    case vibrant, glass, none
}

public struct StyleProps: Equatable, Sendable {
    public var width, height, minWidth, gap, radius, fontSize, opacity, offset: Double?
    public var padding: Insets?
    public var align: Align?
    public var animation: Animation?
    public var material: Material?
    public var background, color, font: String?

    public init(width: Double? = nil, height: Double? = nil, minWidth: Double? = nil, padding: Insets? = nil, gap: Double? = nil, radius: Double? = nil,
                fontSize: Double? = nil, opacity: Double? = nil, offset: Double? = nil, align: Align? = nil, animation: Animation? = nil,
                material: Material? = nil, background: String? = nil, color: String? = nil, font: String? = nil) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.padding = padding
        self.gap = gap
        self.radius = radius
        self.fontSize = fontSize
        self.opacity = opacity
        self.offset = offset
        self.align = align
        self.animation = animation
        self.material = material
        self.background = background
        self.color = color
        self.font = font
    }

    public static let numbers: [(String, WritableKeyPath<StyleProps, Double?>)] = [
        ("width", \.width), ("height", \.height), ("minWidth", \.minWidth), ("gap", \.gap),
        ("radius", \.radius), ("fontSize", \.fontSize), ("opacity", \.opacity),
    ]
    public static let colors: [(String, WritableKeyPath<StyleProps, String?>)] = [("background", \.background), ("color", \.color)]
    public static let names = numbers.map(\.0) + ["padding", "offset", "align", "animation", "material"] + colors.map(\.0) + ["font"]

    public static func parse(_ fields: [String: JSON], fail: (String, String) -> Error) throws -> StyleProps {
        var props = StyleProps()
        for (name, path) in numbers {
            guard let value = fields[name], value != .null else { continue }
            guard let number = value.number, number.isFinite, number >= 0 else { throw fail(name, "must be a non-negative number") }
            if name == "opacity" && number > 1 { throw fail(name, "must be between 0 and 1") }
            props[keyPath: path] = number
        }
        if let value = fields["padding"], value != .null {
            guard let padding = Insets.parse(value) else { throw fail("padding", "must be \(Insets.syntax)") }
            props.padding = padding
        }
        if let value = fields["offset"], value != .null {
            guard let offset = value.number, offset.isFinite else { throw fail("offset", "must be a number") }
            props.offset = offset
        }
        func choice<Value: RawRepresentable & CaseIterable>(_ name: String) throws -> Value? where Value.RawValue == String {
            guard let value = fields[name], value != .null else { return nil }
            guard let choice = value.string.flatMap(Value.init(rawValue:)) else {
                throw fail(name, "must be one of " + Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
            }
            return choice
        }
        props.align = try choice("align")
        props.animation = try choice("animation")
        props.material = try choice("material")
        for (name, path) in colors {
            guard let value = fields[name], value != .null else { continue }
            guard let color = value.string, ColorExpr(color) != nil else { throw fail(name, "must be \(ColorExpr.syntax)") }
            props[keyPath: path] = color
        }
        if let value = fields["font"], value != .null {
            guard let font = value.string else { throw fail("font", "must name a theme font") }
            props.font = font
        }
        return props
    }

    public func over(_ base: StyleProps) -> StyleProps {
        var merged = base
        for (_, path) in Self.numbers where self[keyPath: path] != nil { merged[keyPath: path] = self[keyPath: path] }
        for (_, path) in Self.colors where self[keyPath: path] != nil { merged[keyPath: path] = self[keyPath: path] }
        merged.padding = padding ?? base.padding
        merged.offset = offset ?? base.offset
        merged.align = align ?? base.align
        merged.animation = animation ?? base.animation
        merged.material = material ?? base.material
        merged.font = font ?? base.font
        return merged
    }
}

public struct ResolvedStyle: Equatable, Sendable {
    public var color: RGBA
    public var font: FontToken
    public var background: RGBA?
    public var width, height, minWidth, gap, radius, opacity, offset: Double?
    public var padding: Insets?
    public var align: Align?
    public var animation: Animation?
    public var material: Material?
}
