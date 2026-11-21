import Foundation

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

    public var palette: Palette
    public var colors: [String: RGBA]
    public var fonts: [String: FontToken]
    public var spacing: Spacing
    public var bar: Bar
    public var motion: Motion
    public var styles: [String: StyleProps]
    public var warnings: [String]

    public var mode: Palette.Mode { palette.mode }

    public func color(_ reference: String?) -> RGBA? {
        guard let reference, let expression = ColorExpr(reference) else { return nil }
        return expression.evaluate { colors[$0] ?? palette.colors[$0] }
    }

    public func style(_ name: String?) -> ResolvedStyle { resolve(name) }

    public func resolve(_ name: String?, _ props: StyleProps = StyleProps(), hover: String? = nil) -> ResolvedStyle {
        let fallback = styles["default"]!
        var merged = props.over(name.flatMap { styles[$0] }?.over(fallback) ?? fallback)
        if let hover, let hovered = styles[hover] { merged = hovered.over(merged) }
        var font = merged.font.flatMap { fonts[$0] } ?? fonts[fallback.font!]!
        if let size = merged.fontSize { font.size = size }
        return ResolvedStyle(
            color: color(merged.color) ?? color(fallback.color) ?? palette.foreground, font: font, background: color(merged.background),
            width: merged.width, height: merged.height, padding: merged.padding, gap: merged.gap, radius: merged.radius, opacity: merged.opacity
        )
    }

    public var json: JSON {
        func hexes(_ colors: [String: RGBA]) -> JSON { .object(colors.mapValues { .string($0.hex) }) }
        return .object(["mode": .string(mode.rawValue), "colors": hexes(colors), "palette": hexes(palette.colors)])
    }

    public static func parse(_ base: JSON, override: JSON? = nil, palette: Palette) throws -> Theme {
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
        func chain(_ value: JSON?, _ path: String) throws -> [ColorExpr] {
            guard let value else { return [] }
            let items = value.array ?? [value]
            return try items.enumerated().map { index, item in
                guard let text = item.string, let expression = ColorExpr(text) else {
                    throw fail(value.array == nil ? path : "\(path)[\(index)]", "must be \(ColorExpr.syntax)")
                }
                return expression
            }
        }

        _ = try object(json["colors"], "colors")
        let baseColors = base["colors"]?.object ?? [:], overrideColors = override?["colors"]?.object ?? [:]
        var chains: [String: [ColorExpr]] = [:]
        for name in Set(baseColors.keys).union(overrideColors.keys) {
            chains[name] = try chain(overrideColors[name], "colors.\(name)") + chain(baseColors[name], "colors.\(name)")
        }
        func resolve(_ name: String, _ visiting: Set<String>) -> RGBA? {
            if !visiting.contains(name), let chain = chains[name] {
                for expression in chain {
                    if let color = expression.evaluate({ resolve($0, visiting.union([name])) }) { return color }
                }
            }
            return palette.colors[name]
        }
        var colors: [String: RGBA] = [:]
        var warnings: [String] = []
        for name in chains.keys.sorted() {
            if let color = resolve(name, []) { colors[name] = color } else { warnings.append("colors.\(name): no colour resolves with this palette") }
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
        var theme = Theme(
            palette: palette,
            colors: colors,
            fonts: fonts,
            spacing: Spacing(
                item: try number(spacing["item"], "spacing.item"),
                section: try number(spacing["section"], "spacing.section"),
                edge: try number(spacing["edge"], "spacing.edge")
            ),
            bar: Bar(height: try number(bar["height"], "bar.height"), background: colors["bar"] ?? palette.background),
            motion: Motion(fade: try number(motion["fade"], "motion.fade")),
            styles: [:],
            warnings: []
        )

        for (name, value) in try object(json["styles"], "styles") {
            let path = "styles.\(name)"
            let props = try StyleProps.parse(try object(value, path)) { field, reason in fail("\(path).\(field)", reason) }
            for (field, reference) in [("color", props.color), ("background", props.background)] {
                if let reference, theme.color(reference) == nil { warnings.append("\(path).\(field): no colour \(reference) with this palette") }
            }
            if let font = props.font, fonts[font] == nil { throw fail("\(path).font", "unknown font \(font)") }
            theme.styles[name] = props
        }
        let fallback = try theme.styles["default"] ?? { throw fail("styles.default", "must be an object") }()
        if fallback.color == nil { throw fail("styles.default.color", "must name a color") }
        if fallback.font == nil { throw fail("styles.default.font", "must name a font") }
        theme.warnings = warnings.sorted()
        return theme
    }
}
