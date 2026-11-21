import Foundation

public struct RGBA: Equatable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xff : value
        func channel(_ shift: UInt64) -> Double { Double((rgba >> shift) & 0xff) / 255 }
        self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}

public struct FontToken: Hashable, Sendable {
    public enum Family: Hashable, Sendable {
        case system, monospaced
        case named(String)
    }

    public enum Weight: String, CaseIterable, Sendable {
        case ultralight, thin, light, regular, medium, semibold, bold, heavy, black
    }

    public var family: Family
    public var size: Double
    public var weight: Weight
}

public struct ThemeError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "theme \(path): \(reason)" }
}

public struct Theme: Equatable, Sendable {
    public struct Spacing: Equatable, Sendable {
        public var item: Double
        public var section: Double
        public var edge: Double
    }

    public struct Bar: Equatable, Sendable {
        public var height: Double
        public var background: RGBA
    }

    public struct Motion: Equatable, Sendable {
        public var fade: Double
    }

    public var colors: [String: RGBA]
    public var fonts: [String: FontToken]
    public var spacing: Spacing
    public var bar: Bar
    public var motion: Motion
    public var styles: [String: StyleProps]

    public func style(_ name: String?) -> ResolvedStyle { resolve(name) }

    public func resolve(_ name: String?, _ props: StyleProps = StyleProps(), hover: String? = nil) -> ResolvedStyle {
        let fallback = styles["default"]!
        var merged = props.over(name.flatMap { styles[$0] }?.over(fallback) ?? fallback)
        if let hover, let hovered = styles[hover] { merged = hovered.over(merged) }
        func color(_ reference: String?) -> RGBA? { reference.flatMap { colors[$0] ?? RGBA(hex: $0) } }
        var font = merged.font.flatMap { fonts[$0] } ?? fonts[fallback.font!]!
        if let size = merged.fontSize { font.size = size }
        return ResolvedStyle(
            color: color(merged.color) ?? color(fallback.color)!, font: font, background: color(merged.background),
            width: merged.width, height: merged.height, padding: merged.padding, gap: merged.gap, radius: merged.radius, opacity: merged.opacity
        )
    }

    public static func parse(_ base: JSON, override: JSON? = nil) throws -> Theme {
        let json = override.map { base.merging($0) } ?? base
        func fail(_ path: String, _ reason: String) -> ThemeError { ThemeError(path: path, reason: reason) }
        func object(_ value: JSON?, _ path: String) throws -> [String: JSON] {
            guard let object = value?.object else { throw fail(path, "must be an object") }
            return object
        }
        func number(_ value: JSON?, _ path: String) throws -> Double {
            guard let number = value?.number, number >= 0 else { throw fail(path, "must be a non-negative number") }
            return number
        }

        var colors: [String: RGBA] = [:]
        for (name, value) in try object(json["colors"], "colors") {
            guard let hex = value.string, let color = RGBA(hex: hex) else { throw fail("colors.\(name)", "must be #rrggbb or #rrggbbaa") }
            colors[name] = color
        }
        func color(_ value: JSON?, _ path: String) throws -> RGBA {
            guard let reference = value?.string else { throw fail(path, "must name a color") }
            guard let color = colors[reference] ?? RGBA(hex: reference) else { throw fail(path, "unknown color \(reference)") }
            return color
        }
        func checkColor(_ reference: String?, _ path: String) throws {
            if let reference { _ = try color(.string(reference), path) }
        }

        var fonts: [String: FontToken] = [:]
        for (name, value) in try object(json["fonts"], "fonts") {
            let fields = try object(value, "fonts.\(name)")
            let family: FontToken.Family
            switch fields["family"]?.string {
            case "system"?: family = .system
            case "monospaced"?: family = .monospaced
            case let name?: family = .named(name)
            case nil: throw fail("fonts.\(name).family", "must be a string")
            }
            let weightName = fields["weight"]?.string ?? "regular"
            guard let weight = FontToken.Weight(rawValue: weightName) else { throw fail("fonts.\(name).weight", "unknown weight \(weightName)") }
            fonts[name] = FontToken(family: family, size: try number(fields["size"], "fonts.\(name).size"), weight: weight)
        }
        let spacing = try object(json["spacing"], "spacing")
        let bar = try object(json["bar"], "bar")
        let motion = try object(json["motion"], "motion")

        let styleFields = try object(json["styles"], "styles")
        var styles: [String: StyleProps] = [:]
        for (name, value) in styleFields {
            let path = "styles.\(name)"
            let props = try StyleProps.parse(try object(value, path)) { field, reason in fail("\(path).\(field)", reason) }
            try checkColor(props.color, "\(path).color")
            try checkColor(props.background, "\(path).background")
            if let font = props.font, fonts[font] == nil { throw fail("\(path).font", "unknown font \(font)") }
            styles[name] = props
        }
        let fallback = try styles["default"] ?? { throw fail("styles.default", "must be an object") }()
        if fallback.color == nil { throw fail("styles.default.color", "must name a color") }
        if fallback.font == nil { throw fail("styles.default.font", "must name a font") }

        return Theme(
            colors: colors,
            fonts: fonts,
            spacing: Spacing(
                item: try number(spacing["item"], "spacing.item"),
                section: try number(spacing["section"], "spacing.section"),
                edge: try number(spacing["edge"], "spacing.edge")
            ),
            bar: Bar(height: try number(bar["height"], "bar.height"), background: try color(bar["background"], "bar.background")),
            motion: Motion(fade: try number(motion["fade"], "motion.fade")),
            styles: styles
        )
    }
}
