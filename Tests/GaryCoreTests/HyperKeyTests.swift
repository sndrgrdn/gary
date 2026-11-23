import GaryCore
import Testing

private let control: UInt64 = 0x40000
private let option: UInt64 = 0x80000
private let command: UInt64 = 0x100000
private let shift: UInt64 = 0x20000
private let capsLock: UInt64 = 0x10000
private let function: UInt64 = 0x800000
private let keyA: Int64 = 0
private func mapping(_ source: UInt64, _ destination: UInt64) -> HyperKey.Mapping {
    HyperKey.Mapping(source: source, destination: destination)
}

private func modifiers(_ flags: UInt64) -> [String] {
    [(control, "ctrl"), (option, "alt"), (shift, "shift"), (command, "cmd"), (capsLock, "capslock")].filter { flags & $0.0 != 0 }.map(\.1)
}

private func flags(_ decision: HyperKey.Decision) -> UInt64? {
    switch decision {
    case let .flags(flags), let .modifier(flags), let .tap(flags, _): flags
    case .pass, .drop, .remap: nil
    }
}

private func modifiers(_ decision: HyperKey.Decision) -> [String]? {
    flags(decision).map(modifiers)
}

private let f18Down = HyperKey.Event.keyDown(HyperKey.f18, autorepeat: false)
private let f18Up = HyperKey.Event.keyUp(HyperKey.f18)
private let typeA = HyperKey.Event.keyDown(keyA, autorepeat: false)
private let rightCommand: Int64 = 0x36
private let leftCommand: Int64 = 0x37
private let rightCommandFlag: UInt64 = 0x10
private let leftCommandFlag: UInt64 = 0x08
private let f19: Int64 = 80
private let escape: Int64 = 53
private let millisecond: UInt64 = 1_000_000

private func trigger(_ name: String) -> HyperKey.Trigger {
    HyperKey.Trigger(named: name) ?? .capsLock
}

private func decide(_ events: [(HyperKey.Event, UInt64)], _ options: HyperKey.Options = HyperKey.Options()) -> [HyperKey.Decision] {
    var gate = HyperKey.Gate(options)
    return events.map { gate.decide($0.0, flags: $0.1, at: 0) }
}

private func decide(_ events: [(HyperKey.Event, UInt64)], _ options: HyperKey.Options, every gap: UInt64) -> [HyperKey.Decision] {
    var gate = HyperKey.Gate(options)
    return events.enumerated().map { gate.decide($1.0, flags: $1.1, at: UInt64($0) * gap * millisecond) }
}

struct HyperKeyGateTests {
    @Test func `holding F18 adds control option and command to every key until F18 goes up`() {
        let decisions = decide([(f18Down, function), (typeA, 0), (.keyUp(keyA), 0), (f18Up, function), (typeA, 0)])
        #expect(decisions.map(modifiers) == [["ctrl", "alt", "cmd"], ["ctrl", "alt", "cmd"], ["ctrl", "alt", "cmd"], [], nil])
        #expect(decisions.last == .pass)
    }

    @Test func `the F18 key itself becomes A modifier change, so tapping it alone types nothing`() {
        let decisions = decide([(f18Down, 0), (f18Up, 0)])
        #expect(decisions == [.modifier(HyperKey.Flags.hyper), .modifier(0)])
    }

    @Test func `the shift option adds shift to Hyper, and keys keep the shift the user holds`() {
        #expect(decide([(f18Down, 0), (typeA, 0)], HyperKey.Options(shift: true)).map(modifiers).last == ["ctrl", "alt", "shift", "cmd"])
        #expect(decide([(f18Down, 0), (typeA, 0)]).map(modifiers).last == ["ctrl", "alt", "cmd"])
        #expect(decide([(f18Down, 0), (typeA, shift)]).map(modifiers).last == ["ctrl", "alt", "shift", "cmd"])
    }

    @Test func `repeats of A held F18 are dropped`() {
        let decisions = decide([(f18Down, 0), (.keyDown(HyperKey.f18, autorepeat: true), 0), (typeA, 0)])
        #expect(decisions.dropFirst() == [.drop, .flags(HyperKey.Flags.hyper)])
    }

    @Test func `the Hyper key never carries the caps lock flag`() {
        #expect(decide([(f18Down, capsLock), (typeA, capsLock)]).map(modifiers) == [["ctrl", "alt", "cmd"], ["ctrl", "alt", "cmd"]])
    }

    @Test func `a caps lock that turns on reaches the gate only from A keyboard without the mapping, so it asks to map again`() {
        #expect(decide([(.flagsChanged(HyperKey.capsLock), capsLock), (.flagsChanged(HyperKey.capsLock), 0)]) == [.remap, .pass])
    }

    @Test func `right command as the trigger is Hyper while held, without its own flag, and left command stays command`() {
        let decisions = decide(
            [
                (.flagsChanged(rightCommand), command | rightCommandFlag), (typeA, command | rightCommandFlag), (.flagsChanged(rightCommand), 0),
                (.flagsChanged(leftCommand), command | leftCommandFlag), (typeA, command | leftCommandFlag),
            ],
            HyperKey.Options(trigger: trigger("rightCommand")),
        )
        #expect(decisions.prefix(3).map(modifiers) == [["ctrl", "alt", "cmd"], ["ctrl", "alt", "cmd"], []])
        #expect(decisions.prefix(2).allSatisfy { flags($0).map { $0 & rightCommandFlag == 0 } == true })
        #expect(decisions.suffix(2) == [.pass, .pass])
    }

    @Test func `right shift as the trigger drops shift from Hyper unless left shift is held too`() {
        let options = HyperKey.Options(trigger: trigger("rightShift"))
        #expect(decide([(.flagsChanged(0x3C), shift | 0x04), (typeA, shift | 0x04)], options).map(modifiers).last == ["ctrl", "alt", "cmd"])
        #expect(decide([(.flagsChanged(0x3C), shift | 0x04), (typeA, shift | 0x06)], options).map(modifiers).last == ["ctrl", "alt", "shift", "cmd"])
    }

    @Test func `an ordinary key as the trigger never types and is Hyper while held, and caps lock stays caps lock`() {
        let decisions = decide(
            [
                (.keyDown(f19, autorepeat: false), function), (.keyDown(f19, autorepeat: true), function), (typeA, 0), (.keyUp(f19), function),
                (typeA, 0), (.flagsChanged(HyperKey.capsLock), capsLock),
            ],
            HyperKey.Options(trigger: trigger("f19")),
        )
        #expect(decisions == [.modifier(HyperKey.Flags.hyper), .drop, .flags(HyperKey.Flags.hyper), .modifier(0), .pass, .pass])
    }

    @Test func `tapping the trigger within the tapping term sends the tap key`() {
        let options = HyperKey.Options(tap: .key(escape))
        #expect(decide([(f18Down, 0), (f18Up, shift)], options, every: 199).last == .tap(shift, .key(escape)))
    }

    @Test func `holding the trigger past the tapping term sends no tap`() {
        let options = HyperKey.Options(tap: .key(escape))
        #expect(decide([(f18Down, 0), (f18Up, 0)], options, every: 200).last == .modifier(0))
    }

    @Test func `pressing another key while the trigger is held is Hyper and sends no tap`() {
        let options = HyperKey.Options(tap: .key(escape))
        #expect(decide([(f18Down, 0), (typeA, 0), (f18Up, 0)], options, every: 10).suffix(2) == [.flags(HyperKey.Flags.hyper), .modifier(0)])
    }

    @Test func `the caps lock a tap toggles is not taken for A keyboard without the mapping`() {
        let events: [(HyperKey.Event, UInt64)] = [
            (f18Down, 0),
            (f18Up, 0),
            (.flagsChanged(HyperKey.capsLock), capsLock),
            (.flagsChanged(HyperKey.capsLock), capsLock),
        ]
        #expect(decide(events, HyperKey.Options(tap: .capsLock), every: 10).suffix(3) == [.tap(0, .capsLock), .pass, .remap])
    }

    @Test func `trigger and tap names are the hotkey key names, caps lock, and modifier sides`() {
        #expect(["capsLock", "rightCommand", "leftOption", "fn", "f19", "F13", "escape", "a", ";"].allSatisfy { HyperKey.Trigger(named: $0) != nil })
        #expect(["caps", "rightcommand", "f21", "hyper", ""].allSatisfy { HyperKey.Trigger(named: $0) == nil })
        #expect(HyperKey.Tap(named: "capsLock") == .capsLock && HyperKey.Tap(named: "escape") == .key(escape) && HyperKey
            .Tap(named: "rightCommand") == nil)
    }

    @Test func `letting go reports whether Hyper was held and ends it`() {
        var gate = HyperKey.Gate()
        let idle = gate.letGo()
        _ = gate.decide(f18Down, flags: 0, at: 0)
        let held = gate.letGo()
        let after = gate.decide(typeA, flags: 0, at: 0)
        #expect(!idle && held && after == .pass)
    }
}

struct HyperKeyMappingTests {
    @Test func `claiming maps caps lock to F18 and keeps the keyboard's other mappings`() throws {
        let swap = mapping(0x7_0000_0035, 0x7_0000_0064)
        let claimed = try #require(HyperKey.claim([swap]))
        #expect(claimed.mappings == [swap, HyperKey.capsLockToF18])
        #expect(claimed.replaced.isEmpty)
    }

    @Test func `claiming replaces another caps lock mapping and remembers it`() throws {
        let escape = mapping(0x7_0000_0039, 0x7_0000_0029)
        let claimed = try #require(HyperKey.claim([escape]))
        #expect(claimed.mappings == [HyperKey.capsLockToF18])
        #expect(claimed.replaced == [escape])
        #expect(HyperKey.giveBack(claimed.mappings, restoring: claimed.replaced) == [escape])
    }

    @Test func `a keyboard that already has the mapping needs no write`() {
        #expect(HyperKey.claim([HyperKey.capsLockToF18]) == nil)
    }

    @Test func `the F18 mapping left by A Gary that crashed is never what giving back restores`() throws {
        let leftOver = try #require(HyperKey.claim([HyperKey.capsLockToF18, mapping(0x7_0000_0039, 0x7_0000_0029)]))
        #expect(!leftOver.replaced.contains(HyperKey.capsLockToF18))
        #expect(HyperKey.giveBack([HyperKey.capsLockToF18], restoring: [])?.isEmpty == true)
    }

    @Test func `giving back leaves A caps lock mapping that another app wrote since`() {
        #expect(HyperKey.giveBack([mapping(0x7_0000_0039, 0x7_0000_0029)], restoring: []) == nil)
        #expect(HyperKey.giveBack([], restoring: []) == nil)
    }
}
