import Foundation

public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
        public static let hyper: Modifiers = [.control, .option, .command]
    }

    public let modifiers: Modifiers
    public let key: String
    public let keyCode: UInt32

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option, "shift": .shift, "hyper": .hyper,
    ]

    public static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() {
            codes["f\(index + 1)"] = code
        }
        return codes
    }()

    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = keyCodes[key] else { return nil }
        var modifiers = Modifiers()
        for part in parts.dropLast() {
            guard let modifier = modifierNames[part], modifiers.isDisjoint(with: modifier) else { return nil }
            modifiers.insert(modifier)
        }
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) || key.hasPrefix("f") && key.count > 1 else { return nil }
        return KeyCombo(modifiers: modifiers, key: key, keyCode: code)
    }

    public var description: String {
        let names: [(Modifiers, String)] = [(.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd")]
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
    }
}

public struct Hotkey: Hashable, Sendable {
    public let id: String
    public let keys: KeyCombo

    public init(id: String, keys: KeyCombo) {
        self.id = id
        self.keys = keys
    }
}
