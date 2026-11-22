@testable import GaryCore
import Testing

struct MediaKeyTests {
    @Test func `decodes the key and whether it went down from system defined data`() {
        #expect(MediaKey.decode(systemDefinedData: 0 << 16 | 0x0A00) == MediaKey.Press(key: .volumeUp, down: true, isRepeat: false))
        #expect(MediaKey.decode(systemDefinedData: 1 << 16 | 0x0B00) == MediaKey.Press(key: .volumeDown, down: false, isRepeat: false))
        #expect(MediaKey.decode(systemDefinedData: 7 << 16 | 0x0A00) == MediaKey.Press(key: .mute, down: true, isRepeat: false))
        #expect(MediaKey.decode(systemDefinedData: 2 << 16 | 0x0A00)?.key == .brightnessUp)
        #expect(MediaKey.decode(systemDefinedData: 3 << 16 | 0x0A00)?.key == .brightnessDown)
        #expect(MediaKey.decode(systemDefinedData: 16 << 16 | 0x0A00)?.key == .play)
    }

    @Test func `the next and previous keys and the fast forward and rewind keys some keyboards send are next and previous`() {
        #expect([17, 19].map { MediaKey.decode(systemDefinedData: $0 << 16 | 0x0A00)?.key } == [.next, .next])
        #expect([18, 20].map { MediaKey.decode(systemDefinedData: $0 << 16 | 0x0A00)?.key } == [.previous, .previous])
    }

    @Test func `a held key is marked as A repeat`() {
        #expect(MediaKey.decode(systemDefinedData: 0 << 16 | 0x0A01) == MediaKey.Press(key: .volumeUp, down: true, isRepeat: true))
    }

    @Test func `other system keys and malformed states are not media keys`() {
        #expect(MediaKey.decode(systemDefinedData: 6 << 16 | 0x0A00) == nil)
        #expect(MediaKey.decode(systemDefinedData: 21 << 16 | 0x0A00) == nil)
        #expect(MediaKey.decode(systemDefinedData: 0 << 16 | 0x0C00) == nil)
    }

    struct Tap {
        let key: MediaKey
        let down: Bool
        let intercepted: Bool

        init(_ key: MediaKey, down: Bool, intercepted: Bool) {
            self.key = key
            self.down = down
            self.intercepted = intercepted
        }
    }

    static func swallowed(_ taps: [Tap]) -> [Bool] {
        var gate = MediaKey.Gate()
        return taps.map { gate.swallows(.init(key: $0.key, down: $0.down, isRepeat: false), intercepted: $0.intercepted) }
    }

    @Test func `an intercepted key is swallowed from down through its repeats to up`() {
        #expect(Self.swallowed([
            Tap(.volumeUp, down: true, intercepted: true), Tap(.volumeUp, down: true, intercepted: true), Tap(
                .volumeUp,
                down: false,
                intercepted: true,
            ),
            Tap(.brightnessUp, down: true, intercepted: false), Tap(.brightnessUp, down: false, intercepted: false),
        ]) == [true, true, true, false, false])
    }

    @Test func `a key up whose down reached the system passes so the system key is not left held`() {
        #expect(Self.swallowed([
            Tap(.volumeUp, down: false, intercepted: true),
            Tap(.mute, down: true, intercepted: true), Tap(.mute, down: false, intercepted: true), Tap(.mute, down: false, intercepted: true),
        ]) == [false, true, true, false])
    }

    @Test func `plugins name the keys they intercept`() throws {
        #expect(try MediaKey.parse(["volume-up", "mute", "volume-up"]) == [.volumeUp, .mute])
        #expect(throws: MediaKey.UnknownKey(name: "eject")) { try MediaKey.parse(["volume-up", "eject"]) }
    }
}
