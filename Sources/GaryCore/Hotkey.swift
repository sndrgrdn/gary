import Foundation

public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public let modifiers: KeyModifiers
    public let key: String
    public let keyCode: UInt32

    public static func parse(_ text: String) -> KeyCombo? {
        let (modifiers, rest) = KeyName.split(text)
        let key = rest.trimmingCharacters(in: .whitespaces).lowercased()
        guard let code = KeyName.code(key), !modifiers.isDisjoint(with: .hyper) || KeyName.functionKeys.contains(key) else { return nil }
        return KeyCombo(modifiers: modifiers, key: key, keyCode: UInt32(code))
    }

    static var pattern: String {
        let modifier = alternation(KeyModifiers.aliases.keys)
        let chord = alternation(KeyModifiers.aliases.filter { !$0.value.isDisjoint(with: .hyper) }.keys)
        let key = alternation(KeyName.names + KeyName.hotkeyCodes.keys)
        let function = alternation(KeyName.functionKeys)
        let plus = #"[ \t]*\+[ \t]*"#
        return #"^[ \t]*(?:\#(modifier)\#(plus))*(?:\#(chord)\#(plus)(?:\#(modifier)\#(plus))*\#(key)|\#(function))[ \t]*$"#
    }

    private static func alternation(_ names: some Sequence<String>) -> String {
        let escaped = names.sorted().map { name in
            name.map { character in
                if character.isLetter {
                    "[\(character.lowercased())\(character.uppercased())]"
                } else {
                    #"^$\.*+?()[]{}|/"#.contains(character) ? "\\" + String(character) : String(character)
                }
            }.joined()
        }
        return "(?:" + escaped.joined(separator: "|") + ")"
    }

    public var description: String {
        KeyName.format(modifiers, key)
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
