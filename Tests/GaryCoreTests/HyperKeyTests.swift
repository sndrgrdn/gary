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

private func modifiers(_ decision: HyperKey.Decision) -> [String]? {
    switch decision {
    case let .flags(flags), let .modifier(flags): modifiers(flags)
    case .pass, .drop, .remap: nil
    }
}

private let f18Down = HyperKey.Event.keyDown(HyperKey.f18, autorepeat: false)
private let f18Up = HyperKey.Event.keyUp(HyperKey.f18)
private let typeA = HyperKey.Event.keyDown(keyA, autorepeat: false)

private func decide(_ events: [(HyperKey.Event, UInt64)], shift: Bool = false) -> [HyperKey.Decision] {
    var gate = HyperKey.Gate(shift: shift)
    return events.map { gate.decide($0.0, flags: $0.1) }
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
        #expect(decide([(f18Down, 0), (typeA, 0)], shift: true).map(modifiers).last == ["ctrl", "alt", "shift", "cmd"])
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

    @Test func `letting go reports whether Hyper was held and ends it`() {
        var gate = HyperKey.Gate()
        let idle = gate.letGo()
        _ = gate.decide(f18Down, flags: 0)
        let held = gate.letGo()
        let after = gate.decide(typeA, flags: 0)
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
