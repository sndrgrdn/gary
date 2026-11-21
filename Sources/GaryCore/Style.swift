import CoreGraphics
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

public enum ColorScheme: String, CaseIterable, Sendable {
    case dark, light
}

public enum Transition: String, CaseIterable, Sendable {
    case opacity, scale, none
}

public enum ImageFit: String, CaseIterable, Sendable {
    case fit, fill

    public func pixelSize(source: CGSize, frame: CGSize) -> Int {
        let longest = max(source.width, source.height)
        guard source.width > 0, source.height > 0 else { return Int(max(frame.width, frame.height).rounded(.up)) }
        let widthRatio = frame.width / source.width, heightRatio = frame.height / source.height
        let ratio = self == .fill ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
        return max(1, Int((longest * min(1, ratio)).rounded(.up)))
    }
}

public struct Shadow: Equatable, Sendable {
    public var color: String
    public var radius: Double
    public var y: Double

    public init(color: String, radius: Double = 0, y: Double = 0) {
        self.color = color
        self.radius = radius
        self.y = y
    }
}

public struct Border: Equatable, Sendable {
    public var color: String
    public var width: Double

    public init(color: String, width: Double = 1) {
        self.color = color
        self.width = width
    }
}

public struct StyleProps: Equatable, Sendable {
    public var width, height, minWidth, gap, radius, fontSize, opacity, scale, duration: Double?
    public var offset, x, y, zIndex: Double?
    public var padding: Insets?
    public var align: Align?
    public var animation: Animation?
    public var material: Material?
    public var colorScheme: ColorScheme?
    public var transition: Transition?
    public var fit: ImageFit?
    public var clip: Bool?
    public var shadow: Shadow?
    public var border: Border?
    public var background, color, font: String?

    public init(width: Double? = nil, height: Double? = nil, minWidth: Double? = nil, padding: Insets? = nil, gap: Double? = nil, radius: Double? = nil,
                fontSize: Double? = nil, opacity: Double? = nil, offset: Double? = nil, align: Align? = nil, animation: Animation? = nil,
                material: Material? = nil, background: String? = nil, color: String? = nil, font: String? = nil,
                x: Double? = nil, y: Double? = nil, zIndex: Double? = nil, scale: Double? = nil, duration: Double? = nil,
                transition: Transition? = nil, fit: ImageFit? = nil, clip: Bool? = nil, shadow: Shadow? = nil, border: Border? = nil,
                colorScheme: ColorScheme? = nil) {
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
        self.x = x
        self.y = y
        self.zIndex = zIndex
        self.scale = scale
        self.duration = duration
        self.transition = transition
        self.fit = fit
        self.clip = clip
        self.shadow = shadow
        self.border = border
        self.colorScheme = colorScheme
    }

    public static let numbers: [(String, WritableKeyPath<StyleProps, Double?>)] = [
        ("width", \.width), ("height", \.height), ("minWidth", \.minWidth), ("gap", \.gap),
        ("radius", \.radius), ("fontSize", \.fontSize), ("opacity", \.opacity), ("scale", \.scale), ("duration", \.duration),
    ]
    public static let signed: [(String, WritableKeyPath<StyleProps, Double?>)] = [("offset", \.offset), ("x", \.x), ("y", \.y), ("zIndex", \.zIndex)]
    public static let colors: [(String, WritableKeyPath<StyleProps, String?>)] = [("background", \.background), ("color", \.color)]
    public static let names = numbers.map(\.0) + ["padding"] + signed.map(\.0)
        + ["align", "animation", "material", "colorScheme", "transition", "fit", "clip", "shadow", "border"] + colors.map(\.0) + ["font"]

    public static func parse(_ fields: [String: JSON], fail: (String, String) -> Error) throws -> StyleProps {
        var props = StyleProps()
        for (name, path) in numbers {
            guard let value = fields[name], value != .null else { continue }
            guard let number = value.number, number.isFinite, number >= 0 else { throw fail(name, "must be a non-negative number") }
            if name == "opacity" && number > 1 { throw fail(name, "must be between 0 and 1") }
            props[keyPath: path] = number
        }
        for (name, path) in signed {
            guard let value = fields[name], value != .null else { continue }
            guard let number = value.number, number.isFinite else { throw fail(name, "must be a number") }
            props[keyPath: path] = number
        }
        if let value = fields["padding"], value != .null {
            guard let padding = Insets.parse(value) else { throw fail("padding", "must be \(Insets.syntax)") }
            props.padding = padding
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
        props.colorScheme = try choice("colorScheme")
        props.transition = try choice("transition")
        props.fit = try choice("fit")
        if let value = fields["clip"], value != .null {
            guard let clip = value.bool else { throw fail("clip", "must be true or false") }
            props.clip = clip
        }
        func color(_ value: JSON?, _ name: String) throws -> String {
            guard let color = value?.string, ColorExpr(color) != nil else { throw fail(name, "must be \(ColorExpr.syntax)") }
            return color
        }
        func object(_ name: String, _ syntax: String, _ read: ([String: JSON]) throws -> Void) throws {
            guard let value = fields[name], value != .null else { return }
            guard let object = value.object else { throw fail(name, "must be \(syntax)") }
            try read(object)
        }
        func number(_ value: JSON?, _ name: String, signed: Bool = false) throws -> Double? {
            guard let value, value != .null else { return nil }
            guard let number = value.number, number.isFinite, signed || number >= 0 else {
                throw fail(name, signed ? "must be a number" : "must be a non-negative number")
            }
            return number
        }
        try object("shadow", "an object with color, radius and y") { shadow in
            props.shadow = Shadow(color: try color(shadow["color"], "shadow.color"), radius: try number(shadow["radius"], "shadow.radius") ?? 0,
                                  y: try number(shadow["y"], "shadow.y", signed: true) ?? 0)
        }
        try object("border", "an object with color and width") { border in
            props.border = Border(color: try color(border["color"], "border.color"), width: try number(border["width"], "border.width") ?? 1)
        }
        for (name, path) in colors {
            guard let value = fields[name], value != .null else { continue }
            props[keyPath: path] = try color(value, name)
        }
        if let value = fields["font"], value != .null {
            guard let font = value.string else { throw fail("font", "must name a theme font") }
            props.font = font
        }
        return props
    }

    public func over(_ base: StyleProps) -> StyleProps {
        var merged = base
        for (_, path) in Self.numbers + Self.signed where self[keyPath: path] != nil { merged[keyPath: path] = self[keyPath: path] }
        for (_, path) in Self.colors where self[keyPath: path] != nil { merged[keyPath: path] = self[keyPath: path] }
        merged.padding = padding ?? base.padding
        merged.align = align ?? base.align
        merged.animation = animation ?? base.animation
        merged.material = material ?? base.material
        merged.colorScheme = colorScheme ?? base.colorScheme
        merged.transition = transition ?? base.transition
        merged.fit = fit ?? base.fit
        merged.clip = clip ?? base.clip
        merged.shadow = shadow ?? base.shadow
        merged.border = border ?? base.border
        merged.font = font ?? base.font
        return merged
    }
}

@dynamicMemberLookup
public struct ResolvedStyle: Equatable, Sendable {
    public var props: StyleProps
    public var color: RGBA
    public var font: FontToken
    public var background: RGBA?
    public var shadowColor: RGBA?
    public var borderColor: RGBA?

    public subscript<Value>(dynamicMember path: KeyPath<StyleProps, Value>) -> Value { props[keyPath: path] }
}
