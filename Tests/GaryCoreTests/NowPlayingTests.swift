import Foundation
@testable import GaryCore
import Testing

struct NowPlayingTests {
    static let full = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","playing":true,"title":"Song","artist":"Band","album":"Record","durationMicros":215000000,"elapsedTimeMicros":12500000,"timestampEpochMicros":1795280000123456,"playbackRate":1,"artworkMimeType":"image/png","artworkData":"iVBORw0K"}}"#

    @Test func aFullPayloadDescribesTheTrackInSecondsAndEpochMilliseconds() throws {
        var state = NowPlaying()
        try state.apply(Self.full)
        let track = try #require(state.track)
        #expect(track.app == "com.spotify.client")
        #expect(track.title == "Song")
        #expect(track.artist == "Band")
        #expect(track.album == "Record")
        #expect(track.playing)
        #expect(track.duration == 215)
        #expect(track.elapsed == 12.5)
        #expect(track.elapsedAt == 1_795_280_000_123.456)
        #expect(track.rate == 1)
        #expect(track.artwork == NowPlaying.Artwork(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
    }

    @Test func aDiffUpdatesSomeFieldsKeepsTheRestAndNullRemovesAField() throws {
        var state = NowPlaying()
        try state.apply(Self.full)
        try state.apply(#"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTimeMicros":30000000,"artist":null}}"#)
        let track = try #require(state.track)
        #expect(track.title == "Song")
        #expect(!track.playing)
        #expect(track.elapsed == 30)
        #expect(track.artist == nil)
        #expect(track.artwork != nil)
    }

    @Test func aFullPayloadReplacesTheTrackAndAnEmptyOneMeansNothingIsPlaying() throws {
        var state = NowPlaying()
        try state.apply(Self.full)
        try state.apply(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","playing":false,"title":"Other"}}"#)
        let track = try #require(state.track)
        #expect(track.app == "com.apple.Music")
        #expect(track.artist == nil)
        #expect(track.artwork == nil)
        try state.apply(#"{"type":"data","diff":false,"payload":{}}"#)
        #expect(state.track == nil)
    }

    @Test func mediaPlayedThroughAHelperBelongsToItsParentApplication() throws {
        var state = NowPlaying()
        try state.apply(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","playing":true,"title":"Video"}}"#)
        #expect(state.track?.app == "com.apple.Safari")
    }

    @Test func aPlayerWithoutABundleStillHasATrack() throws {
        var state = NowPlaying()
        try state.apply(#"{"type":"data","diff":false,"payload":{"processIdentifier":76991,"playing":true,"title":"Song"}}"#)
        let track = try #require(state.track)
        #expect(track.app == nil)
        #expect(track.title == "Song")
    }

    @Test func linesThatAreNotAdapterDataAreRejectedAndLeaveTheTrackAlone() throws {
        var state = NowPlaying()
        try state.apply(Self.full)
        #expect(throws: NowPlaying.LineError.self) { try state.apply("Symbol 'adapter_stream_env' not found") }
        #expect(throws: NowPlaying.LineError.self) { try state.apply(#"{"type":"error","payload":{}}"#) }
        #expect(state.track?.title == "Song")
    }
}
