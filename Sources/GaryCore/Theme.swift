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
    public var description: String {
        "theme \(path): \(reason)"
    }
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
        public var fonts: [String: FontToken]
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
    public private(set) var textLines: Int?
    private var fallback: StyleProps
    private var fallbackFont: FontToken

    public var mode: Palette.Mode {
        palette.mode
    }

    public var inBar: Theme {
        var theme = self
        theme.fonts.merge(bar.fonts) { $1 }
        theme.fallbackFont = fallback.font.flatMap { bar.fonts[$0] } ?? fallbackFont
        theme.textLines = 1
        return theme
    }

    public func color(_ reference: String?) -> RGBA? {
        guard let reference, let expression = ColorExpr(reference) else { return nil }
        return expression.evaluate { colors[$0] ?? palette.colors[$0] }
    }

    public func style(_ name: String?) -> ResolvedStyle {
        resolve(name)
    }

    public func resolve(_ name: String?, _ props: StyleProps = StyleProps(), hover: String? = nil) -> ResolvedStyle {
        var merged = props.over(name.flatMap { styles[$0] }?.over(fallback) ?? fallback)
        if let hover, let hovered = styles[hover] {
            merged = hovered.over(merged)
        }
        var font = merged.font.flatMap { fonts[$0] } ?? fallbackFont
        if let size = merged.fontSize {
            font.size = size
        }
        return ResolvedStyle(
            props: merged, color: color(merged.color) ?? color(fallback.color) ?? palette.foreground, font: font,
            background: paint(merged.background),
            shadowColor: color(merged.shadow?.color), borderColor: color(merged.border?.color),
        )
    }

    public var json: JSON {
        func hexes(_ colors: [String: RGBA]) -> JSON {
            .object(colors.mapValues { .string($0.hex) })
        }
        return .object([
            "mode": .string(mode.rawValue), "colors": hexes(colors), "palette": hexes(palette.colors),
            "spacing": .object(["item": .number(spacing.item), "section": .number(spacing.section), "edge": .number(spacing.edge)]),
        ])
    }

    public static func parse(_ base: JSON, palette: Palette, override: JSON? = nil) throws -> Theme {
        let json = override.map { base.merging($0) } ?? base
        _ = try object(json["colors"], "colors")
        let (colors, colorWarnings) = try resolveColors(
            base: base["colors"]?.object ?? [:],
            override: override?["colors"]?.object ?? [:],
            palette: palette,
        )
        let spacingFields = try object(json["spacing"], "spacing")
        let barFields = try object(json["bar"], "bar")
        let motionFields = try object(json["motion"], "motion")
        let fonts = try fonts(json["fonts"], "fonts")
        let spacing = try Spacing(
            item: number(spacingFields["item"], "spacing.item"),
            section: number(spacingFields["section"], "spacing.section"),
            edge: number(spacingFields["edge"], "spacing.edge"),
        )
        let bar = try Bar(
            height: number(barFields["height"], "bar.height"), background: colors["bar"] ?? palette.background,
            fonts: barFields["fonts"] == nil ? [:] : Self.fonts(barFields["fonts"], "bar.fonts"),
        )
        let motion = try Motion(fade: number(motionFields["fade"], "motion.fade"))
        let styles = try styles(json["styles"], fonts: fonts)
        guard let fallback = styles["default"] else { throw ThemeError(path: "styles.default", reason: "must be an object") }
        if fallback.color == nil {
            throw ThemeError(path: "styles.default.color", reason: "must name a color")
        }
        guard let fallbackFont = fallback.font.flatMap({ fonts[$0] })
        else { throw ThemeError(path: "styles.default.font", reason: "must name a font") }
        var theme = Theme(
            palette: palette, colors: colors, fonts: fonts, spacing: spacing, bar: bar, motion: motion,
            styles: styles, warnings: [], textLines: nil, fallback: fallback, fallbackFont: fallbackFont,
        )
        theme.warnings = (colorWarnings + theme.styleWarnings()).sorted()
        return theme
    }

    private static func object(_ value: JSON?, _ path: String) throws -> [String: JSON] {
        guard let object = value?.object else { throw ThemeError(path: path, reason: "must be an object") }
        return object
    }

    private static func number(_ value: JSON?, _ path: String) throws -> Double {
        guard let number = value?.number, number >= 0 else { throw ThemeError(path: path, reason: "must be a non-negative number") }
        return number
    }

    private static func resolveColors(
        base: [String: JSON],
        override: [String: JSON],
        palette: Palette,
    ) throws -> (colors: [String: RGBA], warnings: [String]) {
        var chains: [String: [ColorExpr]] = [:]
        for name in Set(base.keys).union(override.keys) {
            chains[name] = try chain(override[name], "colors.\(name)") + chain(base[name], "colors.\(name)")
        }
        func resolve(_ name: String, _ visiting: Set<String>) -> RGBA? {
            if !visiting.contains(name), let chain = chains[name] {
                for expression in chain {
                    if let color = expression.evaluate({ resolve($0, visiting.union([name])) }) {
                        return color
                    }
                }
            }
            return palette.colors[name]
        }
        var colors: [String: RGBA] = [:]
        var warnings: [String] = []
        for name in chains.keys.sorted() {
            if let color = resolve(name, []) {
                colors[name] = color
            } else {
                warnings.append("colors.\(name): no colour resolves with this palette")
            }
        }
        return (colors, warnings)
    }

    private static func chain(_ value: JSON?, _ path: String) throws -> [ColorExpr] {
        guard let value else { return [] }
        let items = value.array ?? [value]
        return try items.enumerated().map { index, item in
            guard let text = item.string, let expression = ColorExpr(text) else {
                throw ThemeError(path: value.array == nil ? path : "\(path)[\(index)]", reason: "must be \(ColorExpr.syntax)")
            }
            return expression
        }
    }

    private static func fonts(_ value: JSON?, _ path: String) throws -> [String: FontToken] {
        try object(value, path).reduce(into: [:]) { fonts, entry in
            let (name, value) = entry
            fonts[name] = try font(object(value, "\(path).\(name)"), "\(path).\(name)")
        }
    }

    private static func font(_ fields: [String: JSON], _ path: String) throws -> FontToken {
        let family: FontToken.Family
        switch fields["family"]?.string {
        case "system": family = .system
        case "monospaced": family = .monospaced
        case let name?: family = .named(name)
        case nil: throw ThemeError(path: "\(path).family", reason: "must be a string")
        }
        let weightName = fields["weight"]?.string ?? "regular"
        guard let weight = FontToken.Weight(rawValue: weightName) else { throw ThemeError(
            path: "\(path).weight",
            reason: "unknown weight \(weightName)",
        ) }
        return try FontToken(family: family, size: number(fields["size"], "\(path).size"), weight: weight)
    }

    private static func styles(_ value: JSON?, fonts: [String: FontToken]) throws -> [String: StyleProps] {
        try object(value, "styles").reduce(into: [:]) { styles, entry in
            let (name, value) = entry
            let path = "styles.\(name)"
            let props = try StyleProps.parse(object(value, path)) { field, reason in ThemeError(path: "\(path).\(field)", reason: reason) }
            if let font = props.font, fonts[font] == nil {
                throw ThemeError(path: "\(path).font", reason: "unknown font \(font)")
            }
            styles[name] = props
        }
    }

    private func styleWarnings() -> [String] {
        styles.flatMap { name, props in
            ([("color", props.color)] + (props.background?.colors ?? []).map { ("background", $0) }).compactMap { field, reference in
                guard let reference, color(reference) == nil else { return nil }
                return "styles.\(name).\(field): no colour \(reference) with this palette"
            }
        }
    }
}
