import Foundation

public struct PaletteFile: Equatable, Sendable {
    public var mode: Palette.Mode?
    public var colors: [String: RGBA]
    public var ignored: [String]

    public static func parse(_ text: String) -> PaletteFile {
        var file = PaletteFile(mode: nil, colors: [:], ignored: [])
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            switch entry(line) {
            case let .failure(error):
                file.ignored.append("line \(index + 1): \(error.reason)")
            case let .success(("mode", value)):
                guard let mode = Palette.Mode(rawValue: value) else {
                    file.ignored.append("line \(index + 1): mode must be light or dark")
                    continue
                }
                file.mode = mode
            case let .success((key, value)):
                guard let color = RGBA(hex: value) else {
                    if Palette.baseKeys.contains(key) {
                        file.ignored.append("line \(index + 1): \(key) is not #rgb, #rrggbb or #rrggbbaa")
                    }
                    continue
                }
                file.colors[key] = color
            }
        }
        return file
    }

    private struct LineError: Error {
        let reason: String
    }

    private static func entry(_ line: String) -> Result<(String, String), LineError> {
        guard let equals = line.firstIndex(of: "=") else { return .failure(LineError(reason: "not key = \"value\"")) }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            return .failure(LineError(reason: "\"\(key)\" is not a bare key"))
        }
        let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            let value = rest.prefix { !$0.isWhitespace }
            let after = rest.dropFirst(value.count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, after.isEmpty || after.hasPrefix("#") else { return .failure(LineError(reason: "\(key) has no single value")) }
            return .success((key, String(value)))
        }
        let body = rest.dropFirst()
        guard let close = body.firstIndex(of: quote) else { return .failure(LineError(reason: "\(key) has an unterminated string")) }
        let after = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return .failure(LineError(reason: "\(key) has text after its value")) }
        return .success((key, String(body[..<close])))
    }
}

public struct Palette: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case light, dark
    }

    public static let baseKeys = ["background", "foreground", "accent"]

    public let mode: Mode
    public let colors: [String: RGBA]
    public let background: RGBA
    public let foreground: RGBA

    public init(_ file: PaletteFile?, system: Mode) {
        let mode = file?.mode ?? file?.colors["background"].map { $0.isLight ? .light : .dark } ?? system
        let builtin = Self.builtinColors(mode)
        var colors = file?.colors ?? builtin.colors
        for key in Self.baseKeys where colors[key] == nil {
            colors[key] = builtin.colors[key]
        }
        self.mode = mode
        self.colors = colors
        background = colors["background"] ?? builtin.background
        foreground = colors["foreground"] ?? builtin.foreground
    }

    public static func builtin(_ mode: Mode) -> PaletteFile {
        PaletteFile(mode: mode, colors: builtinColors(mode).colors, ignored: [])
    }

    private static func builtinColors(_ mode: Mode) -> BuiltinColors {
        switch mode {
        case .dark: .dark
        case .light: .light
        }
    }
}

private struct BuiltinColors {
    static let dark = BuiltinColors(background: 0x1A1B26, foreground: 0xA9B1D6, others: [
        "accent": 0x7AA2F7,
        "dark_foreground": 0x565F89,
        "bright_foreground": 0xC0CAF5,
        "lighter_background": 0x24283B,
        "green": 0x9ECE6A,
        "red": 0xF7768E,
    ])

    static let light = BuiltinColors(background: 0xF4F4F6, foreground: 0x383A42, others: [
        "accent": 0x2E6FD9,
        "dark_foreground": 0x80838D,
        "bright_foreground": 0x16171C,
        "lighter_background": 0xFFFFFF,
        "green": 0x3D8B40,
        "red": 0xD73A49,
    ])

    let background: RGBA
    let foreground: RGBA
    let colors: [String: RGBA]

    init(background: UInt64, foreground: UInt64, others: [String: UInt64]) {
        func opaque(_ rgb: UInt64) -> RGBA {
            RGBA(rgba: rgb << 8 | 0xFF)
        }
        self.background = opaque(background)
        self.foreground = opaque(foreground)
        colors = others.mapValues(opaque).merging(["background": self.background, "foreground": self.foreground]) { $1 }
    }
}
