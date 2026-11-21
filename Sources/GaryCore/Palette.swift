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
            if line.isEmpty || line.hasPrefix("#") { continue }
            switch entry(line) {
            case .failure(let error):
                file.ignored.append("line \(index + 1): \(error.reason)")
            case .success(("mode", let value)):
                guard let mode = Palette.Mode(rawValue: value) else {
                    file.ignored.append("line \(index + 1): mode must be light or dark")
                    continue
                }
                file.mode = mode
            case .success((let key, let value)):
                guard let color = RGBA(hex: value) else {
                    file.ignored.append("line \(index + 1): \(key) is not #rgb, #rrggbb or #rrggbbaa")
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

    public init(_ file: PaletteFile?, system: Mode) {
        let mode = file?.mode ?? file?.colors["background"].map { $0.isLight ? .light : .dark } ?? system
        let builtin = Self.builtin(mode).colors
        var colors = file?.colors ?? builtin
        for key in Self.baseKeys where colors[key] == nil { colors[key] = builtin[key] }
        self.mode = mode
        self.colors = colors
    }

    public var background: RGBA { colors["background"]! }
    public var foreground: RGBA { colors["foreground"]! }

    public static func builtin(_ mode: Mode) -> PaletteFile {
        switch mode {
        case .dark: return builtinDark
        case .light: return builtinLight
        }
    }

    private static let builtinDark = PaletteFile.parse("""
    mode = "dark"
    background = "#1a1b26"
    foreground = "#a9b1d6"
    accent = "#7aa2f7"
    dark_foreground = "#565f89"
    bright_foreground = "#c0caf5"
    lighter_background = "#24283b"
    green = "#9ece6a"
    red = "#f7768e"
    """)

    private static let builtinLight = PaletteFile.parse("""
    mode = "light"
    background = "#f4f4f6"
    foreground = "#383a42"
    accent = "#2e6fd9"
    dark_foreground = "#80838d"
    bright_foreground = "#16171c"
    lighter_background = "#ffffff"
    green = "#3d8b40"
    red = "#d73a49"
    """)
}
