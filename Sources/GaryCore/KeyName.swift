import Foundation

public enum KeyName {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public static let named: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 36: "enter", 76: "enter", 53: "escape", 48: "tab",
        51: "backspace", 117: "delete", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    ]

    public static func name(keyCode: UInt16, characters: String?, ignoringModifiers: String?, modifiers: Modifiers) -> String? {
        let chord = modifiers.intersection([.control, .option, .command])
        let base: String
        if let name = named[keyCode] {
            base = name
        } else if let text = chord.isEmpty ? characters : ignoringModifiers?.lowercased(), text.count == 1,
                  let scalar = text.unicodeScalars.first, scalar.value >= 32, scalar.value != 127, !(0xF700...0xF8FF).contains(scalar.value) {
            base = text
        } else {
            return nil
        }
        let shown = named[keyCode] == nil ? chord : modifiers
        let prefix = [(Modifiers.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd")].filter { shown.contains($0.0) }.map { $0.1 + "+" }
        return prefix.joined() + base
    }
}
