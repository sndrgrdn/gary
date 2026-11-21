import Foundation

public struct StyleProps: Equatable, Sendable {
    public var width, height, padding, gap, radius, fontSize, opacity: Double?
    public var background, color, font: String?

    public init(width: Double? = nil, height: Double? = nil, padding: Double? = nil, gap: Double? = nil, radius: Double? = nil,
                fontSize: Double? = nil, opacity: Double? = nil, background: String? = nil, color: String? = nil, font: String? = nil) {
        self.width = width
        self.height = height
        self.padding = padding
        self.gap = gap
        self.radius = radius
        self.fontSize = fontSize
        self.opacity = opacity
        self.background = background
        self.color = color
        self.font = font
    }

    public static let numbers: [(String, WritableKeyPath<StyleProps, Double?>)] = [
        ("width", \.width), ("height", \.height), ("padding", \.padding), ("gap", \.gap),
        ("radius", \.radius), ("fontSize", \.fontSize), ("opacity", \.opacity),
    ]
    public static let colors: [(String, WritableKeyPath<StyleProps, String?>)] = [("background", \.background), ("color", \.color)]

    public static func parse(_ fields: [String: JSON], fail: (String, String) -> Error) throws -> StyleProps {
        var props = StyleProps()
        for (name, path) in numbers {
            guard let value = fields[name], value != .null else { continue }
            guard let number = value.number, number.isFinite, number >= 0 else { throw fail(name, "must be a non-negative number") }
            if name == "opacity" && number > 1 { throw fail(name, "must be between 0 and 1") }
            props[keyPath: path] = number
        }
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
        if font != nil { merged.font = font }
        return merged
    }
}

public struct ResolvedStyle: Equatable, Sendable {
    public var color: RGBA
    public var font: FontToken
    public var background: RGBA?
    public var width, height, padding, gap, radius, opacity: Double?
}
