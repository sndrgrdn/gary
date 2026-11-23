import CryptoKit
import Foundation
import GaryCore

nonisolated extension Capability {
    static let nowplaying = Capability(name: "nowplaying", summary: "The track that any app is playing. Play, pause, skip, and seek.", types: """
    declare namespace Gary {
      type NowPlaying = { available: boolean; reason?: string; track: Track | null }
      type Track = {
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
    """, example: """
    export default {
      render(state) {
        const track = state.nowplaying?.track;
        if (!track) return { type: "text", text: "" };
        return {
          type: "row",
          action: "toggle",
          children: [
            { type: "icon", key: "state", symbol: track.playing ? "pause.fill" : "play.fill" },
            { type: "text", key: "title", text: track.artist ? `${track.artist} – ${track.title}` : track.title },
          ],
        };
      },
      onAction(action) {
        if (action === "toggle") host.nowplaying.toggle();
      },
    } satisfies Gary.BarWidget;
    """, install: { host, plugin in
        plugin.installAPI(host, "nowplaying", NowPlayingRequest.methods) { call in
            switch try NowPlayingRequest.parse(call) {
            case .play: try Adapter.run(["send", "0"])
            case .pause: try Adapter.run(["send", "1"])
            case .toggle: try Adapter.run(["send", "2"])
            case .next: try Adapter.run(["send", "4"])
            case .previous: try Adapter.run(["send", "5"])
            case let .seek(seconds): try Adapter.run(["seek", String(Int64(seconds * 1_000_000))])
            }
            return .now(.null)
        }
    }, topic: CapabilityTopic(type: "NowPlaying") { NowPlayingTopic($0) })
}

private nonisolated struct Adapter {
    static let artwork = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.sndrgrdn.gary/nowplaying")

    let script: URL
    let framework: URL

    static func bundled() throws -> Self {
        try Self(
            script: bundledFile(Bundle.main.resourceURL, "mediaremote-adapter/mediaremote-adapter.pl"),
            framework: bundledFile(Bundle.main.privateFrameworksURL, "MediaRemoteAdapter.framework"),
        )
    }

    private static func bundledFile(_ directory: URL?, _ path: String) throws -> URL {
        guard let url = directory?.appending(path: path), FileManager.default.fileExists(atPath: url.path) else {
            throw HostFailure("\(URL(filePath: path).lastPathComponent) is not bundled")
        }
        return url
    }

    func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.standardInput = FileHandle.nullDevice
        return process
    }

    static func run(_ arguments: [String]) throws {
        let adapter: Self
        do { adapter = try bundled() } catch { throw HostFailure("now playing is unavailable: \(error)") }
        let process = adapter.process(arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process
            .terminationHandler = {
                if $0.terminationStatus != 0 {
                    log("nowplaying: \(arguments.joined(separator: " ")) exited with \($0.terminationStatus)")
                }
            }
        do { try process.run() } catch { throw HostFailure("cannot run the now playing adapter: \(error.localizedDescription)") }
    }
}

private final nonisolated class NowPlayingTopic: TopicFeed, @unchecked Sendable {
    private let publish: @Sendable (JSON, Trace) -> Void
    private let queue = DispatchQueue(label: "gary.nowplaying")
    private var stream: (process: Process, output: Pipe)?
    private var state = NowPlaying()
    private var buffer = Data()
    private var failures = 0
    private var stopped = false
    private var artworkPath: (digest: String, path: String)?

    init(_ publish: @escaping @Sendable (JSON, Trace) -> Void) {
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
        let adapter: Adapter
        do { adapter = try Adapter.bundled() } catch {
            publish(
                .object(["available": .bool(false), "reason": .string("\(error)"), "track": .null]),
                Trace("nowplaying"),
            )
            return
        }
        let process = adapter.process(["stream", "--micros", "--debounce=50"])
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.queue.async { [weak self] in self?.received(data) }
            }
        }
        let started = Date()
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            let errorOutput = errors.fileHandleForReading.availableData
            let reason = String(bytes: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.queue.async { [weak self] in self?.ended(
                status: process.terminationStatus,
                reason: reason,
                ranFor: Date().timeIntervalSince(started),
            ) }
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
        publish(
            .object(["available": .bool(false), "reason": .string(reason.isEmpty ? "the adapter exited with \(status)" : reason), "track": .null]),
            Trace("nowplaying"),
        )
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(bytes: buffer[buffer.startIndex..<newline], encoding: .utf8)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line else {
                log("nowplaying: adapter printed a line that is not UTF-8")
                continue
            }
            do {
                try state.apply(line)
                changed = true
            } catch {
                log("nowplaying: \(error)")
            }
        }
        if changed {
            publish(snapshot(), Trace("nowplaying"))
        }
    }

    private func snapshot() -> JSON {
        guard let track = state.track else { return .object(["available": .bool(true), "track": .null]) }
        func number(_ value: Double?) -> JSON {
            value.map(JSON.number) ?? .null
        }
        func string(_ value: String?) -> JSON {
            value.map(JSON.string) ?? .null
        }
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
        if let artworkPath, artworkPath.digest == digest {
            return artworkPath.path
        }
        let fileExtension = artwork.mimeType.split(separator: "/").last.map(String.init) ?? "img"
        let url = Adapter.artwork.appending(path: "\(digest).\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: Adapter.artwork, withIntermediateDirectories: true)
            try artwork.data.write(to: url, options: .atomic)
        } catch {
            log("nowplaying: artwork not saved: \(error)")
            return nil
        }
        if let previous = artworkPath?.path {
            try? FileManager.default.removeItem(atPath: previous)
        }
        artworkPath = (digest, url.path)
        return url.path
    }
}
