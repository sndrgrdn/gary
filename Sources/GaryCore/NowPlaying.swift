import Foundation

public struct NowPlaying: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public let app: String?
        public let title: String
        public let artist: String?
        public let album: String?
        public let playing: Bool
        public let duration: Double?
        public let elapsed: Double?
        public let elapsedAt: Double?
        public let rate: Double?
        public let artwork: Artwork?
    }

    public struct Artwork: Equatable, Sendable {
        public let mimeType: String
        public let data: Data
    }

    public struct LineError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    private var fields: [String: JSON] = [:]

    public init() {}

    public mutating func apply(_ line: String) throws {
        guard let json = try? JSON.parse(line) else { throw LineError(description: "adapter printed a line that is not JSON") }
        guard json["type"]?.string == "data", let diff = json["diff"]?.bool, let payload = json["payload"]?.object else {
            throw LineError(description: "adapter printed an object without type, diff and payload")
        }
        if !diff {
            fields = [:]
        }
        for (key, value) in payload {
            fields[key] = value == .null ? nil : value
        }
    }

    public var track: Track? {
        guard let title = fields["title"]?.string, let playing = fields["playing"]?.bool else { return nil }
        let app = fields["parentApplicationBundleIdentifier"]?.string ?? fields["bundleIdentifier"]?.string
        func seconds(_ key: String) -> Double? {
            fields[key]?.number.map { $0 / 1_000_000 }
        }
        return Track(
            app: app, title: title, artist: fields["artist"]?.string, album: fields["album"]?.string, playing: playing,
            duration: seconds("durationMicros"), elapsed: seconds("elapsedTimeMicros"),
            elapsedAt: fields["timestampEpochMicros"]?.number.map { $0 / 1000 }, rate: fields["playbackRate"]?.number,
            artwork: fields["artworkData"]?.string.flatMap { Data(base64Encoded: $0) }.map {
                Artwork(mimeType: fields["artworkMimeType"]?.string ?? "image/jpeg", data: $0)
            },
        )
    }
}
