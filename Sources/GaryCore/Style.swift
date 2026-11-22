import CoreGraphics
import Foundation

public struct Insets: Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(_ all: Double) {
        self.init(top: all, right: all, bottom: all, left: all)
    }

    public static let syntax = "a number, [vertical, horizontal], or [top, right, bottom, left]"

    static func parse(_ value: JSON) -> Insets? {
        let sides = value.array ?? [value]
        let numbers = sides.compactMap(\.number).filter(\.isFinite).map { max(0, $0) }
        guard numbers.count == sides.count else { return nil }
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
    case smooth, spring
    case instant = "none"
}

public enum Material: String, CaseIterable, Sendable {
    case vibrant, glass
    case plain = "none"
}

public enum ColorScheme: String, CaseIterable, Sendable {
    case dark, light
}

public enum Transition: String, CaseIterable, Sendable {
    case opacity, scale
    case identity = "none"
}

public enum ImageFit: String, CaseIterable, Sendable {
    case fit, fill

    public func pixelSize(source: CGSize, frame: CGSize) -> Int {
        let longest = max(source.width, source.height)
        guard source.width > 0, source.height > 0 else { return Int(max(frame.width, frame.height).rounded(.up)) }
        let widthRatio = frame.width / source.width
        let heightRatio = frame.height / source.height
        let ratio = self == .fill ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
        return max(1, Int((longest * min(1, ratio)).rounded(.up)))
    }
}

public enum Truncation: String, CaseIterable, Sendable {
    case tail, middle, head
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
    public var width: Double?
    public var height: Double?
    public var minWidth: Double?
    public var gap: Double?
    public var radius: Double?
    public var fontSize: Double?
    public var opacity: Double?
    public var scale: Double?
    public var duration: Double?
    public var blur: Double?
    public var rotation: Double?
    public var x: Double?
    public var y: Double?
    public var zIndex: Double?
    public var padding: Insets?
    public var align: Align?
    public var animation: Animation?
    public var material: Material?
    public var colorScheme: ColorScheme?
    public var transition: Transition?
    public var fit: ImageFit?
    public var lines: Int?
    public var truncate: Truncation?
    public var clip: Bool?
    public var shadow: Shadow?
    public var border: Border?
    public var blend: Blend?
    public var loop: Loop?
    public var background: Paint?
    public var color: String?
    public var font: String?

    public init(
        width: Double? = nil,
        height: Double? = nil,
        minWidth: Double? = nil,
        padding: Insets? = nil,
        gap: Double? = nil,
        radius: Double? = nil,
        fontSize: Double? = nil,
        opacity: Double? = nil,
        align: Align? = nil,
        animation: Animation? = nil,
        material: Material? = nil,
        background: Paint? = nil,
        color: String? = nil,
        font: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        zIndex: Double? = nil,
        scale: Double? = nil,
        duration: Double? = nil,
        transition: Transition? = nil,
        fit: ImageFit? = nil,
        clip: Bool? = nil,
        shadow: Shadow? = nil,
        border: Border? = nil,
        colorScheme: ColorScheme? = nil,
        rotation: Double? = nil,
        blur: Double? = nil,
        blend: Blend? = nil,
        loop: Loop? = nil,
        lines: Int? = nil,
        truncate: Truncation? = nil,
    ) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.padding = padding
        self.gap = gap
        self.radius = radius
        self.fontSize = fontSize
        self.opacity = opacity
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
        self.rotation = rotation
        self.blur = blur
        self.blend = blend
        self.loop = loop
        self.lines = lines
        self.truncate = truncate
    }

    public static let numbers: [(String, WritableKeyPath<StyleProps, Double?> & Sendable)] = [
        ("width", \.width), ("height", \.height), ("minWidth", \.minWidth), ("gap", \.gap),
        ("radius", \.radius), ("fontSize", \.fontSize), ("opacity", \.opacity), ("scale", \.scale), ("duration", \.duration),
        ("blur", \.blur),
    ]
    public static let signed: [(String, WritableKeyPath<StyleProps, Double?> & Sendable)] = [
        ("x", \.x),
        ("y", \.y),
        ("zIndex", \.zIndex),
        ("rotation", \.rotation),
    ]
    public static let colors: [(String, WritableKeyPath<StyleProps, String?> & Sendable)] = [("color", \.color)]
    public static let names = numbers.map(\.0) + ["padding"] + signed.map(\.0)
        + [
            "align",
            "animation",
            "material",
            "colorScheme",
            "transition",
            "fit",
            "lines",
            "truncate",
            "clip",
            "shadow",
            "border",
            "blend",
            "loop",
            "background",
        ]
        + colors.map(\.0) + ["font"]

    public static func parse(_ fields: [String: JSON], fail: (String, String) -> Error) throws -> StyleProps {
        var props = StyleProps()
        for (name, path) in numbers {
            let value = try number(fields[name], name, fail: fail)
            props[keyPath: path] = name == "opacity" ? value.map { min(1, $0) } : value
        }
        for (name, path) in signed {
            props[keyPath: path] = try number(fields[name], name, signed: true, fail: fail)
        }
        props.padding = try present(fields["padding"]).map { value in
            guard let padding = Insets.parse(value) else { throw fail("padding", "must be \(Insets.syntax)") }
            return padding
        }
        props.align = try choice(fields["align"], "align", fail: fail)
        props.animation = try choice(fields["animation"], "animation", fail: fail)
        props.material = try choice(fields["material"], "material", fail: fail)
        props.colorScheme = try choice(fields["colorScheme"], "colorScheme", fail: fail)
        props.transition = try choice(fields["transition"], "transition", fail: fail)
        props.fit = try choice(fields["fit"], "fit", fail: fail)
        props.lines = try present(fields["lines"]).map { value in
            guard let lines = value.number, lines.rounded() == lines else { throw fail("lines", "must be a whole number") }
            return Int(min(max(lines, 1), Double(Int32.max)))
        }
        props.truncate = try choice(fields["truncate"], "truncate", fail: fail)
        props.blend = try choice(fields["blend"], "blend", fail: fail)
        props.clip = try flag(fields["clip"], "clip", fail: fail)
        props.shadow = try object(fields["shadow"], "shadow", "an object with color, radius and y", fail: fail) { shadow in
            try Shadow(
                color: color(shadow["color"], "shadow.color", fail: fail),
                radius: number(shadow["radius"], "shadow.radius", fail: fail) ?? 0,
                y: number(shadow["y"], "shadow.y", signed: true, fail: fail) ?? 0,
            )
        }
        props.border = try object(fields["border"], "border", "an object with color and width", fail: fail) { border in
            try Border(color: color(border["color"], "border.color", fail: fail), width: number(border["width"], "border.width", fail: fail) ?? 1)
        }
        props.loop = try object(fields["loop"], "loop", Loop.syntax, fail: fail) { try loop($0, fail: fail) }
        props.background = try paint(fields["background"], "background", fail: fail)
        for (name, path) in colors {
            props[keyPath: path] = try present(fields[name]).map { try color($0, name, fail: fail) }
        }
        props.font = try present(fields["font"]).map { value in
            guard let font = value.string else { throw fail("font", "must name a theme font") }
            return font
        }
        return props
    }

    static func present(_ value: JSON?) -> JSON? {
        value == .null ? nil : value
    }

    static func flag(_ value: JSON?, _ name: String, fail: (String, String) -> Error) throws -> Bool? {
        try present(value).map { value in
            guard let flag = value.bool else { throw fail(name, "must be true or false") }
            return flag
        }
    }

    static func paint(_ value: JSON?, _ name: String, fail: (String, String) -> Error) throws -> Paint? {
        try present(value).map { value in
            guard let paint = Paint.parse(value) else { throw fail(name, "must be \(Paint.syntax)") }
            return paint
        }
    }

    static func number(_ value: JSON?, _ name: String, signed: Bool = false, fail: (String, String) -> Error) throws -> Double? {
        guard let value = present(value) else { return nil }
        guard let number = value.number, number.isFinite else { throw fail(name, "must be a number") }
        return signed ? number : max(0, number)
    }

    static func choice<Value: RawRepresentable & CaseIterable>(
        _ value: JSON?,
        _ name: String,
        fail: (String, String) -> Error,
    ) throws -> Value? where Value.RawValue == String {
        guard let value = present(value) else { return nil }
        guard let choice = value.string.flatMap(Value.init(rawValue:)) else {
            throw fail(name, "must be one of " + Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
        }
        return choice
    }

    private static func color(_ value: JSON?, _ name: String, fail: (String, String) -> Error) throws -> String {
        guard let color = value?.string, ColorExpr(color) != nil else { throw fail(name, "must be \(ColorExpr.syntax)") }
        return color
    }

    private static func object<Value>(
        _ value: JSON?,
        _ name: String,
        _ syntax: String,
        fail: (String, String) -> Error,
        _ read: ([String: JSON]) throws -> Value,
    ) throws -> Value? {
        guard let value = present(value) else { return nil }
        guard let object = value.object else { throw fail(name, "must be \(syntax)") }
        return try read(object)
    }

    public func over(_ base: StyleProps) -> StyleProps {
        var merged = base
        for (_, path) in Self.numbers + Self.signed where self[keyPath: path] != nil {
            merged[keyPath: path] = self[keyPath: path]
        }
        for (_, path) in Self.colors where self[keyPath: path] != nil {
            merged[keyPath: path] = self[keyPath: path]
        }
        merged.padding = padding ?? base.padding
        merged.align = align ?? base.align
        merged.animation = animation ?? base.animation
        merged.material = material ?? base.material
        merged.colorScheme = colorScheme ?? base.colorScheme
        merged.transition = transition ?? base.transition
        merged.fit = fit ?? base.fit
        merged.lines = lines ?? base.lines
        merged.truncate = truncate ?? base.truncate
        merged.clip = clip ?? base.clip
        merged.shadow = shadow ?? base.shadow
        merged.border = border ?? base.border
        merged.blend = blend ?? base.blend
        merged.loop = loop ?? base.loop
        merged.background = background ?? base.background
        merged.font = font ?? base.font
        return merged
    }
}

@dynamicMemberLookup
public struct ResolvedStyle: Equatable, Sendable {
    public var props: StyleProps
    public var color: RGBA
    public var font: FontToken
    public var background: ResolvedPaint?
    public var shadowColor: RGBA?
    public var borderColor: RGBA?

    public subscript<Value>(dynamicMember path: KeyPath<StyleProps, Value>) -> Value {
        props[keyPath: path]
    }
}

extension StyleProps {
    private static func loop(_ fields: [String: JSON], fail: (String, String) -> Error) throws -> Loop {
        var spans: [Loop.Property: Loop.Span] = [:]
        for property in Loop.Property.allCases {
            guard let value = present(fields[property.rawValue]) else { continue }
            let ends = value.array?.compactMap(\.number).filter(\.isFinite) ?? []
            guard ends.count == 2, value.array?.count == 2 else { throw fail("loop.\(property.rawValue)", "must be [from, to]") }
            spans[property] = property == .opacity ? Loop.Span(min(1, max(0, ends[0])), min(1, max(0, ends[1]))) : Loop.Span(ends[0], ends[1])
        }
        let duration = try number(fields["duration"], "loop.duration", fail: fail) ?? 1
        guard duration > 0 else { throw fail("loop.duration", "must be a positive number") }
        return try Loop(spans, duration: duration, reverse: flag(fields["reverse"], "loop.reverse", fail: fail) ?? false)
    }
}
