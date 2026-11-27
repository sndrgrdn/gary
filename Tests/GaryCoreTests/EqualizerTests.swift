@testable import GaryCore
import Testing

struct EqualizerTests {
    private func call(_ method: String, _ arguments: JSON...) -> HostCall {
        HostCall(api: "audio", method: method, arguments: arguments)
    }

    @Test func `audio sets an equalizer of bands, or turns it off with null`() throws {
        let bands: JSON = .array([
            .object(["type": .string("lowShelf"), "frequency": .number(105), "gain": .number(5.5), "q": .number(0.71)]),
            .object(["type": .string("peak"), "frequency": .number(3000)]),
        ])
        #expect(try AudioRequest.parse(call("setEqualizer", .object(["preamp": .number(-6), "bands": bands]))) == .setEqualizer(
            Equalizer(preamp: -6, bands: [
                Equalizer.Band(.lowShelf, frequency: 105, gain: 5.5, qFactor: 0.71),
                Equalizer.Band(.peak, frequency: 3000, gain: 0),
            ]),
        ))
        #expect(try AudioRequest.parse(call("setEqualizer", .null)) == .setEqualizer(nil))
        #expect(try AudioRequest.parse(call("setEqualizer")) == .setEqualizer(nil))
    }

    @Test func `audio rejects an equalizer band out of range or of an unknown type`() {
        let rejected: [(JSON, String)] = [
            (
                .object(["bands": .array([.object(["type": .string("notch"), "frequency": .number(100)])])]),
                "bands[0].type must be \"peak\" or \"lowShelf\" or \"highShelf\"",
            ),
            (
                .object(["bands": .array([.object(["type": .string("peak"), "frequency": .number(5)])])]),
                "bands[0].frequency must be a number from 20 to 20000 Hz",
            ),
            (
                .object(["bands": .array([.object(["type": .string("peak"), "frequency": .number(100), "gain": .number(40)])])]),
                "bands[0].gain must be a number from -30 to 30 dB",
            ),
            (.object(["bands": .array([.object(["type": .string("peak")])])]), "bands[0].frequency must be a number"),
            (.object(["preamp": .number(-3)]), "bands must be an array"),
            (.object(["bands": .array([]), "bass": .number(1)]), "unknown field \"bass\" in equalizer; use preamp, bands"),
            (
                .object(["bands": .array(Array(repeating: .object(["type": .string("peak"), "frequency": .number(100)]), count: 17))]),
                "bands must have at most 16 entries",
            ),
            (.number(1), "equalizer must be an object or null"),
        ]
        for (argument, reason) in rejected {
            #expect(throws: ArgumentError("host.audio.setEqualizer: \(reason)")) {
                try AudioRequest.parse(call("setEqualizer", argument))
            }
        }
    }

    private let rate = 48000.0

    @Test func `a peak band boosts its centre frequency by its gain and leaves distant frequencies alone`() {
        let biquad = Biquad(Equalizer.Band(.peak, frequency: 1000, gain: 6, qFactor: 1), sampleRate: rate)
        #expect(abs(biquad.decibels(at: 1000, sampleRate: rate) - 6) < 0.01)
        #expect(abs(biquad.decibels(at: 20, sampleRate: rate)) < 0.1)
        #expect(abs(biquad.decibels(at: 18000, sampleRate: rate)) < 0.1)
    }

    @Test func `a low shelf raises the bass by its gain and leaves the treble alone`() {
        let biquad = Biquad(Equalizer.Band(.lowShelf, frequency: 105, gain: 6), sampleRate: rate)
        #expect(abs(biquad.decibels(at: 20, sampleRate: rate) - 6) < 0.3)
        #expect(abs(biquad.decibels(at: 105, sampleRate: rate) - 3) < 0.1)
        #expect(abs(biquad.decibels(at: 5000, sampleRate: rate)) < 0.1)
    }

    @Test func `a high shelf cuts the treble by its gain and leaves the bass alone`() {
        let biquad = Biquad(Equalizer.Band(.highShelf, frequency: 8000, gain: -4), sampleRate: rate)
        #expect(abs(biquad.decibels(at: 20000, sampleRate: rate) + 4) < 0.3)
        #expect(abs(biquad.decibels(at: 100, sampleRate: rate)) < 0.1)
    }

    @Test func `a band at or above the Nyquist frequency passes the sound unchanged`() {
        #expect(Biquad(Equalizer.Band(.peak, frequency: 12000, gain: 6), sampleRate: 22050) == .identity)
    }

    @Test func `the preamp scales by its gain in decibels`() {
        #expect(abs(Equalizer(preamp: -6, bands: []).preampScale - 0.501) < 0.001)
    }
}
