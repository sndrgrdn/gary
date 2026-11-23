import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
    public static let hyper: KeyModifiers = [.control, .option, .command]

    static let names: [(modifier: KeyModifiers, name: String)] = [(.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd")]
    static let aliases: [String: KeyModifiers] = Dictionary(uniqueKeysWithValues: names.map { ($0.name, $0.modifier) })
        .merging(["command": .command, "control": .control, "opt": .option, "option": .option, "hyper": .hyper]) { $1 }
}

public enum KeyName {
    static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let functionKeys = functionKeyCodes.indices.map { "f\($0 + 1)" }

    struct Named {
        let name: String
        let code: UInt16
        let character: unichar
    }

    static let named = [
        Named(name: "left", code: 123, character: 0xF702), Named(name: "right", code: 124, character: 0xF703),
        Named(name: "down", code: 125, character: 0xF701), Named(name: "up", code: 126, character: 0xF700),
        Named(name: "enter", code: 36, character: 0x0D), Named(name: "enter", code: 76, character: 0x03),
        Named(name: "escape", code: 53, character: 0x1B), Named(name: "tab", code: 48, character: 0x09),
        Named(name: "backspace", code: 51, character: 0x7F), Named(name: "delete", code: 117, character: 0xF728),
        Named(name: "home", code: 115, character: 0xF729), Named(name: "end", code: 119, character: 0xF72B),
        Named(name: "pageup", code: 116, character: 0xF72C), Named(name: "pagedown", code: 121, character: 0xF72D),
    ] + functionKeyCodes.enumerated().map { Named(name: functionKeys[$0], code: $1, character: unichar(0xF704 + $0)) }

    static let hotkeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, "return": 36, "space": 49, "esc": 53,
    ]

    public static let names: [String] = named.map(\.name).reduce(into: []) { names, name in
        if !names.contains(name) {
            names.append(name)
        }
    }

    static func code(_ name: String) -> UInt16? {
        named.first { $0.name == name }?.code ?? hotkeyCodes[name]
    }

    static func format(_ modifiers: KeyModifiers, _ key: String) -> String {
        (KeyModifiers.names.filter { modifiers.contains($0.modifier) }.map(\.name) + [key]).joined(separator: "+")
    }

    static func split(_ text: String) -> (modifiers: KeyModifiers, key: Substring) {
        var modifiers = KeyModifiers()
        var rest = Substring(text)
        while let plus = rest.dropFirst().firstIndex(of: "+"), rest.index(after: plus) < rest.endIndex,
              let modifier = KeyModifiers.aliases[rest[..<plus].trimmingCharacters(in: .whitespaces).lowercased()],
              modifiers.isDisjoint(with: modifier)
        {
            modifiers.insert(modifier)
            rest = rest[rest.index(after: plus)...]
        }
        return (modifiers, rest)
    }
}

public struct KeyStroke: Equatable, Sendable {
    public var keyCode: UInt16
    public var characters: String?
    public var ignoringModifiers: String?
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, characters: String?, ignoringModifiers: String?, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.characters = characters
        self.ignoringModifiers = ignoringModifiers
        self.modifiers = modifiers
    }

    public init?(named name: String) {
        let (modifiers, key) = KeyName.split(name)
        let named = KeyName.named.first { $0.name == key }
        let unmodified = named.map { String(utf16CodeUnits: [$0.character], count: 1) } ?? String(key)
        self.init(
            keyCode: KeyName.code(key.lowercased()) ?? 0,
            characters: key == "tab" && modifiers.contains(.shift) ? "\u{19}" : unmodified,
            ignoringModifiers: unmodified,
            modifiers: modifiers,
        )
        guard self.name == name else { return nil }
    }

    public var name: String? {
        if let named = KeyName.named.first(where: { $0.code == keyCode }) {
            return KeyName.format(modifiers, named.name)
        }
        let chord = !modifiers.isDisjoint(with: .hyper)
        guard let text = chord ? ignoringModifiers?.lowercased() : characters, text.count == 1, let scalar = text.unicodeScalars.first,
              scalar.value >= 32, scalar.value != 127, !(0xF700...0xF8FF).contains(scalar.value)
        else {
            return nil
        }
        return KeyName.format(chord ? modifiers : [], text)
    }
}
