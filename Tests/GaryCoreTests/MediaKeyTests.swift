import Testing
@testable import GaryCore

struct MediaKeyTests {
    @Test func decodesTheKeyAndWhetherItWentDownFromSystemDefinedData() {
        #expect(MediaKey.decode(systemDefinedData: 0 << 16 | 0x0A00) == MediaKey.Press(key: .volumeUp, down: true, isRepeat: false))
        #expect(MediaKey.decode(systemDefinedData: 1 << 16 | 0x0B00) == MediaKey.Press(key: .volumeDown, down: false, isRepeat: false))
        #expect(MediaKey.decode(systemDefinedData: 7 << 16 | 0x0A00) == MediaKey.Press(key: .mute, down: true, isRepeat: false))
        #expect(MediaKey.decode(systemDefinedData: 2 << 16 | 0x0A00)?.key == .brightnessUp)
        #expect(MediaKey.decode(systemDefinedData: 3 << 16 | 0x0A00)?.key == .brightnessDown)
    }

    @Test func aHeldKeyIsMarkedAsARepeat() {
        #expect(MediaKey.decode(systemDefinedData: 0 << 16 | 0x0A01) == MediaKey.Press(key: .volumeUp, down: true, isRepeat: true))
    }

    @Test func otherSystemKeysAndMalformedStatesAreNotMediaKeys() {
        #expect(MediaKey.decode(systemDefinedData: 16 << 16 | 0x0A00) == nil)
        #expect(MediaKey.decode(systemDefinedData: 21 << 16 | 0x0A00) == nil)
        #expect(MediaKey.decode(systemDefinedData: 0 << 16 | 0x0C00) == nil)
    }

    static func swallowed(_ presses: [(MediaKey, down: Bool, intercepted: Bool)]) -> [Bool] {
        var gate = MediaKey.Gate()
        return presses.map { gate.swallows(.init(key: $0.0, down: $0.down, isRepeat: false), intercepted: $0.intercepted) }
    }

    @Test func anInterceptedKeyIsSwallowedFromDownThroughItsRepeatsToUp() {
        #expect(Self.swallowed([
            (.volumeUp, down: true, intercepted: true), (.volumeUp, down: true, intercepted: true), (.volumeUp, down: false, intercepted: true),
            (.brightnessUp, down: true, intercepted: false), (.brightnessUp, down: false, intercepted: false),
        ]) == [true, true, true, false, false])
    }

    @Test func aKeyUpWhoseDownReachedTheSystemPassesSoTheSystemKeyIsNotLeftHeld() {
        #expect(Self.swallowed([
            (.volumeUp, down: false, intercepted: true),
            (.mute, down: true, intercepted: true), (.mute, down: false, intercepted: true), (.mute, down: false, intercepted: true),
        ]) == [false, true, true, false])
    }

    @Test func pluginsNameTheKeysTheyIntercept() throws {
        #expect(try MediaKey.parse(["volume-up", "mute", "volume-up"]) == [.volumeUp, .mute])
        #expect(throws: MediaKey.UnknownKey(name: "play")) { try MediaKey.parse(["volume-up", "play"]) }
    }
}
