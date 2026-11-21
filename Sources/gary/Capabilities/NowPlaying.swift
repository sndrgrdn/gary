import CryptoKit
import Foundation
import GaryCore

extension Capability {
    static let nowplaying = Capability(name: "nowplaying", summary: "The track that any app is playing. Play, pause, skip, and seek.", types: """
    declare namespace Gary {
      interface State { nowplaying?: NowPlaying }
      interface NowPlaying { available: boolean; reason?: string; track: Track | null }
      interface Track {
        app: string | null;
        title: string;
        artist: string | null;
        album: string | null;
        playing: boolean;
        duration: number | null;
        elapsed: number | null;
        elapsedAt: number | null;
        rate: number | null;
        artwork: string | null;
      }
      interface Host { nowplaying: NowPlayingApi }
      interface NowPlayingApi {
        play(): null;
        pause(): null;
        toggle(): null;
        next(): null;
        previous(): null;
        seek(seconds: number): null;
      }
    }
    """, install: { host, plugin in
        plugin.installAPI(host, "nowplaying", NowPlayingRequest.methods) { call in
            switch try NowPlayingRequest.parse(call) {
            case .play: try Adapter.run(["send", "0"])
            case .pause: try Adapter.run(["send", "1"])
            case .toggle: try Adapter.run(["send", "2"])
            case .next: try Adapter.run(["send", "4"])
            case .previous: try Adapter.run(["send", "5"])
            case .seek(let seconds): try Adapter.run(["seek", String(Int64(seconds * 1_000_000))])
            }
            return .now(.null)
        }
    }, topic: { NowPlayingTopic($0) })
}

private enum Adapter {
    static let script = Bundle.main.resourceURL!.appending(path: "mediaremote-adapter/mediaremote-adapter.pl")
    static let framework = Bundle.main.privateFrameworksURL!.appending(path: "MediaRemoteAdapter.framework")
    static let artwork = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.sndrgrdn.gary/nowplaying")

    static var missing: String? {
        for url in [script, framework] where !FileManager.default.fileExists(atPath: url.path) { return "\(url.lastPathComponent) is not bundled" }
        return nil
    }

    static func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.standardInput = FileHandle.nullDevice
        return process
    }

    static func run(_ arguments: [String]) throws {
        if let missing { throw HostFailure("now playing is unavailable: \(missing)") }
        let process = process(arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { if $0.terminationStatus != 0 { log("nowplaying: \(arguments.joined(separator: " ")) exited with \($0.terminationStatus)") } }
        do { try process.run() } catch { throw HostFailure("cannot run the now playing adapter: \(error.localizedDescription)") }
    }
}

private final class NowPlayingTopic {
    private let publish: (JSON, Trace) -> Void
    private let queue = DispatchQueue(label: "gary.nowplaying")
    private var stream: (process: Process, output: Pipe)?
    private var state = NowPlaying()
    private var buffer = Data()
    private var failures = 0
    private var stopped = false
    private var artworkPath: (digest: String, path: String)?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        queue.async { [weak self] in self?.start() }
    }

    deinit {
        stopped = true
        stream?.output.fileHandleForReading.readabilityHandler = nil
        stream?.process.terminationHandler = nil
        stream?.process.terminate()
    }

    private func start() {
        guard !stopped else { return }
        if let missing = Adapter.missing { return publish(.object(["available": .bool(false), "reason": .string(missing), "track": .null]), Trace("nowplaying")) }
        let process = Adapter.process(["stream", "--micros", "--debounce=50"])
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.queue.async { self?.received(data) } }
        }
        let started = Date()
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            let reason = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            self?.queue.async { self?.ended(status: process.terminationStatus, reason: reason, ranFor: Date().timeIntervalSince(started)) }
        }
        do {
            try process.run()
            stream = (process, output)
            publish(snapshot(), Trace("nowplaying-start"))
        } catch {
            ended(status: -1, reason: "\(error)", ranFor: 0)
        }
    }

    private func ended(status: Int32, reason: String, ranFor seconds: TimeInterval) {
        guard !stopped else { return }
        stream = nil
        buffer = Data()
        state = NowPlaying()
        failures = seconds > 30 ? 1 : failures + 1
        let delay = min(60, pow(2, Double(failures)))
        log("nowplaying: adapter exited with \(status) after \(Int(seconds)) s\(reason.isEmpty ? "" : ": \(reason)"); restarting in \(Int(delay)) s")
        publish(.object(["available": .bool(false), "reason": .string(reason.isEmpty ? "the adapter exited with \(status)" : reason), "track": .null]), Trace("nowplaying"))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            do {
                try state.apply(line)
                changed = true
            } catch {
                log("nowplaying: \(error)")
            }
        }
        if changed { publish(snapshot(), Trace("nowplaying")) }
    }

    private func snapshot() -> JSON {
        guard let track = state.track else { return .object(["available": .bool(true), "track": .null]) }
        func number(_ value: Double?) -> JSON { value.map(JSON.number) ?? .null }
        func string(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
        return .object([
            "available": .bool(true),
            "track": .object([
                "app": string(track.app), "title": .string(track.title), "artist": string(track.artist), "album": string(track.album),
                "playing": .bool(track.playing), "duration": number(track.duration), "elapsed": number(track.elapsed),
                "elapsedAt": number(track.elapsedAt), "rate": number(track.rate), "artwork": string(track.artwork.flatMap(save)),
            ]),
        ])
    }

    private func save(_ artwork: NowPlaying.Artwork) -> String? {
        let digest = SHA256.hash(data: artwork.data).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let artworkPath, artworkPath.digest == digest { return artworkPath.path }
        let fileExtension = artwork.mimeType.split(separator: "/").last.map(String.init) ?? "img"
        let url = Adapter.artwork.appending(path: "\(digest).\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: Adapter.artwork, withIntermediateDirectories: true)
            try artwork.data.write(to: url, options: .atomic)
        } catch {
            log("nowplaying: artwork not saved: \(error)")
            return nil
        }
        if let previous = artworkPath?.path { try? FileManager.default.removeItem(atPath: previous) }
        artworkPath = (digest, url.path)
        return url.path
    }
}
