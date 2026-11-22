import AppKit
import GaryCore
import ScreenCaptureKit

extension Capability {
    static let screen = Capability(
        name: "screen",
        summary: """
        Capture a display, a window, or a region of the screen to a PNG file and the clipboard, or record it to a .mov or .mp4 file. \
        `select()` lets the user drag a region or click a window or the desktop, and resolves with that area, or null after escape or a \
        right click. A region is in points from the top left of the main display, and a recorded region must lie on one display. A plugin \
        runs one recording at a time, and Gary stops it and finishes the file when `stopRecording()` runs or the plugin stops. With \
        `audio`, the recording includes the sound the Mac plays. \
        Hide the plugin's own surface before you select, capture, or record, or it shows in the image.
        """,
        types: """
        declare namespace Gary {
          interface Host { screen: ScreenApi }
          interface ScreenApi {
            select(): Promise<ScreenArea | null>;
            capture(area: ScreenArea, options?: { path?: string; clipboard?: boolean }): Promise<string>;
            record(area: ScreenArea, path: string, options?: { audio?: boolean }): Promise<string>;
            stopRecording(): Promise<string | null>;
          }
        }
        """,
        example: """
        export default {
          async onAction() {
            host.hide();
            const area = await host.screen.select();
            if (!area) return;
            const path = await host.screen.capture(area, { path: `~/Pictures/Screenshot ${Date.now()}.png`, clipboard: true });
            host.log(`saved ${path}`);
          },
          render() {
            return { type: "text", text: "Screenshot", action: "shoot" };
          },
        } satisfies Gary.Menu;
        """,
        permissions: [.screenRecording],
        install: { host, plugin in
            let folder = plugin.bundle.directory.path
            let recorder = ScreenRecorder()
            plugin.onStop { Task { await recorder.close() } }
            plugin.installAPI(host, "screen", ScreenRequest.methods) { call in
                switch try ScreenRequest.parse(call, home: home, folder: folder) {
                case .select:
                    .pending { finish in DispatchQueue.main.async { ScreenSelection.run(finish) } }
                case let .capture(area, path, clipboard):
                    .task { try await .string(screenshot(area, to: path, clipboard: clipboard)) }
                case let .record(area, path, audio):
                    .task { try await .string(recorder.start(area, to: path, audio: audio)) }
                case .stopRecording:
                    .task { try await recorder.stop().map(JSON.string) ?? .null }
                }
            }
        },
    )
}

extension HostResult {
    static func task(_ work: @escaping () async throws -> JSON) -> HostResult {
        .pending { finish in
            Task {
                do {
                    try await finish(.success(work()))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }
}

private func screenshot(_ area: ScreenArea, to path: String?, clipboard: Bool) async throws -> String {
    let image = try await captureImage(area)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw HostFailure("the capture cannot be encoded as PNG")
    }
    if clipboard {
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
    }
    guard let path else { return try savePNG(png, in: "screen") }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url, options: .atomic)
    return path
}

func captureImage(_ area: ScreenArea) async throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else { throw HostFailure(missingGrant(.screenRecording, "screen capture")) }
    if case let .region(rect) = area {
        return try await SCScreenshotManager.captureImage(in: rect)
    }
    let source = try await captureSource(area)
    return try await SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: source.configuration)
}

func captureSource(_ area: ScreenArea) async throws -> (filter: SCContentFilter, configuration: SCStreamConfiguration) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let filter: SCContentFilter
    var rect: CGRect?
    switch area {
    case let .display(id):
        guard let display = content.displays.first(where: { displayID(id) == $0.displayID }) else { throw HostFailure("no display \(id ?? "main")") }
        filter = SCContentFilter(display: display, excludingWindows: [])
    case let .window(id):
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw HostFailure("no window \(id) on screen") }
        filter = SCContentFilter(desktopIndependentWindow: window)
    case let .region(region):
        guard let display = content.displays.first(where: { $0.frame.contains(region) }) else {
            throw HostFailure("the region must lie on one display")
        }
        filter = SCContentFilter(display: display, excludingWindows: [])
        rect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }
    let configuration = SCStreamConfiguration()
    let size = rect?.size ?? filter.contentRect.size
    configuration.width = Int((size.width * CGFloat(filter.pointPixelScale)).rounded())
    configuration.height = Int((size.height * CGFloat(filter.pointPixelScale)).rounded())
    configuration.sourceRect = rect ?? .null
    configuration.showsCursor = false
    return (filter, configuration)
}

private actor ScreenRecorder {
    private enum State {
        case idle, starting
        case recording(SCStream, path: String, end: RecordingEnd)
    }

    private var state = State.idle
    private var closed = false

    func start(_ area: ScreenArea, to path: String, audio: Bool) async throws -> String {
        guard !closed, case .idle = state else { throw HostFailure("a recording is running; call stopRecording first") }
        guard CGPreflightScreenCaptureAccess() else { throw HostFailure(missingGrant(.screenRecording, "screen recording")) }
        state = .starting
        do {
            let source = try await captureSource(area)
            source.configuration.width &= ~1
            source.configuration.height &= ~1
            source.configuration.showsCursor = true
            source.configuration.capturesAudio = audio
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(at: url)
            }
            let output = SCRecordingOutputConfiguration()
            output.outputURL = url
            output.outputFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
            let end = RecordingEnd()
            let stream = SCStream(filter: source.filter, configuration: source.configuration, delegate: nil)
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: end))
            try await stream.startCapture()
            state = .recording(stream, path: path, end: end)
        } catch {
            state = .idle
            throw error
        }
        if closed {
            _ = try await stop()
        }
        return path
    }

    func stop() async throws -> String? {
        guard case let .recording(stream, path, end) = state else { return nil }
        state = .idle
        try? await stream.stopCapture()
        try await end.finished()
        return path
    }

    func close() async {
        closed = true
        _ = try? await stop()
    }
}

private final class RecordingEnd: NSObject, SCRecordingOutputDelegate {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func recordingOutputDidFinishRecording(_: SCRecordingOutput) {
        settle(.success(()))
    }

    func recordingOutput(_: SCRecordingOutput, didFailWithError error: Error) {
        settle(.failure(error))
    }

    func finished() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result {
                    continuation.resume(with: result)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    private func settle(_ outcome: Result<Void, Error>) {
        lock.withLock {
            guard result == nil else { return }
            result = outcome
            waiter?.resume(with: outcome)
            waiter = nil
        }
    }
}

private func displayID(_ uuid: String?) -> CGDirectDisplayID? {
    guard let uuid else { return CGMainDisplayID() }
    let screen = NSScreen.screens.first { $0.uuid == uuid }
    return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
