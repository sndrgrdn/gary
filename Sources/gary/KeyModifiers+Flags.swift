import AppKit
import Carbon
import GaryCore

nonisolated struct ModifierKey {
    let modifier: KeyModifiers
    let flag: NSEvent.ModifierFlags
    let eventFlag: CGEventFlags
    let carbonFlag: Int
    let code: CGKeyCode
}

nonisolated extension KeyModifiers {
    static let keys = [
        ModifierKey(modifier: .control, flag: .control, eventFlag: .maskControl, carbonFlag: controlKey, code: 59),
        ModifierKey(modifier: .option, flag: .option, eventFlag: .maskAlternate, carbonFlag: optionKey, code: 58),
        ModifierKey(modifier: .shift, flag: .shift, eventFlag: .maskShift, carbonFlag: shiftKey, code: 56),
        ModifierKey(modifier: .command, flag: .command, eventFlag: .maskCommand, carbonFlag: cmdKey, code: 55),
    ]

    init(_ flags: NSEvent.ModifierFlags) {
        self.init(Self.keys.filter { flags.contains($0.flag) }.map(\.modifier))
    }

    var held: [ModifierKey] {
        Self.keys.filter { contains($0.modifier) }
    }
}
