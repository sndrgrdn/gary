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
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit), let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xff : value
        func channel(_ shift: UInt64) -> Double { Double((rgba >> shift) & 0xff) / 255 }
        self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    public var hex: String {
        let channels = alpha < 1 ? [red, green, blue, alpha] : [red, green, blue]
        return "#" + channels.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    public var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public var isLight: Bool { luminance > 0.179 }

    public func mixed(with other: RGBA, _ amount: Double) -> RGBA {
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return RGBA(red: blend(red, other.red), green: blend(green, other.green), blue: blend(blue, other.blue), alpha: blend(alpha, other.alpha))
    }
}

public indirect enum ColorExpr: Equatable, Sendable {
    case literal(RGBA)
    case name(String)
    case mix(ColorExpr, ColorExpr, Double)
    case alpha(ColorExpr, Double)
    case contrast(ColorExpr)

    public static let syntax = "a theme or palette colour name, #rgb, #rrggbb, #rrggbbaa, mix(a, b, t), alpha(a, t) or contrast(a)"

    public init?(_ text: String) {
        var parser = Parser(rest: Substring(text))
        guard let expression = parser.expression(), parser.atEnd else { return nil }
        self = expression
    }

    public func evaluate(_ lookup: (String) -> RGBA?) -> RGBA? {
        switch self {
        case .literal(let color): return color
        case .name(let name): return lookup(name)
        case .mix(let a, let b, let amount):
            guard let a = a.evaluate(lookup), let b = b.evaluate(lookup) else { return nil }
            return a.mixed(with: b, amount)
        case .alpha(let base, let alpha):
            guard var color = base.evaluate(lookup) else { return nil }
            color.alpha = alpha
            return color
        case .contrast(let base):
            guard let color = base.evaluate(lookup) else { return nil }
            return color.isLight ? RGBA(red: 0, green: 0, blue: 0) : RGBA(red: 1, green: 1, blue: 1)
        }
    }

    private struct Parser {
        var rest: Substring

        var atEnd: Bool { rest.allSatisfy(\.isWhitespace) }

        mutating func word() -> Substring? {
            rest = rest.drop(while: \.isWhitespace)
            let word = rest.prefix { $0.isLetter || $0.isNumber || "#_-.".contains($0) }
            rest = rest.dropFirst(word.count)
            return word.isEmpty ? nil : word
        }

        mutating func take(_ character: Character) -> Bool {
            rest = rest.drop(while: \.isWhitespace)
            guard rest.first == character else { return false }
            rest = rest.dropFirst()
            return true
        }

        mutating func fraction() -> Double? {
            guard let word = word(), let value = Double(word), (0...1).contains(value) else { return nil }
            return value
        }

        mutating func expression() -> ColorExpr? {
            guard let word = word() else { return nil }
            if word.hasPrefix("#") { return RGBA(hex: String(word)).map(ColorExpr.literal) }
            guard let first = word.first, first.isLetter || first == "_" else { return nil }
            guard take("(") else { return .name(String(word)) }
            switch word {
            case "mix":
                guard let a = expression(), take(","), let b = expression(), take(","), let amount = fraction(), take(")") else { return nil }
                return .mix(a, b, amount)
            case "alpha":
                guard let base = expression(), take(","), let alpha = fraction(), take(")") else { return nil }
                return .alpha(base, alpha)
            case "contrast":
                guard let base = expression(), take(")") else { return nil }
                return .contrast(base)
            default:
                return nil
            }
        }
    }
}
