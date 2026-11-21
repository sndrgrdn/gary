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

public struct FontToken: Equatable, Sendable {
    public enum Family: Equatable, Sendable {
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

public struct Style: Equatable, Sendable {
    public var color: RGBA
    public var font: FontToken
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

    public struct Panel: Equatable, Sendable {
        public var background: RGBA
        public var radius: Double
        public var padding: Double
    }

    public var colors: [String: RGBA]
    public var fonts: [String: FontToken]
    public var spacing: Spacing
    public var bar: Bar
    public var panel: Panel
    public var styles: [String: Style]

    public func style(_ name: String?) -> Style {
        name.flatMap { styles[$0] } ?? styles["default"]!
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
        func font(_ value: JSON?, _ path: String) throws -> FontToken {
            guard let name = value?.string else { throw fail(path, "must name a font") }
            guard let font = fonts[name] else { throw fail(path, "unknown font \(name)") }
            return font
        }

        let spacing = try object(json["spacing"], "spacing")
        let bar = try object(json["bar"], "bar")
        let panel = try object(json["panel"], "panel")

        let styleFields = try object(json["styles"], "styles")
        let defaultFields = try object(styleFields["default"], "styles.default")
        let fallback = Style(color: try color(defaultFields["color"], "styles.default.color"), font: try font(defaultFields["font"], "styles.default.font"))
        var styles: [String: Style] = [:]
        for (name, value) in styleFields {
            let fields = try object(value, "styles.\(name)")
            styles[name] = Style(
                color: try fields["color"].map { try color($0, "styles.\(name).color") } ?? fallback.color,
                font: try fields["font"].map { try font($0, "styles.\(name).font") } ?? fallback.font
            )
        }

        return Theme(
            colors: colors,
            fonts: fonts,
            spacing: Spacing(
                item: try number(spacing["item"], "spacing.item"),
                section: try number(spacing["section"], "spacing.section"),
                edge: try number(spacing["edge"], "spacing.edge")
            ),
            bar: Bar(height: try number(bar["height"], "bar.height"), background: try color(bar["background"], "bar.background")),
            panel: Panel(
                background: try color(panel["background"], "panel.background"),
                radius: try number(panel["radius"], "panel.radius"),
                padding: try number(panel["padding"], "panel.padding")
            ),
            styles: styles
        )
    }
}
