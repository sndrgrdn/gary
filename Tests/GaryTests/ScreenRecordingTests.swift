import AVFoundation
import CoreGraphics
import Foundation
@testable import gary
import Testing

struct ScreenRecordingTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess())) func `stopping the plugin finishes its recording into A playable movie`() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "gary-recording-\(UUID().uuidString).mov").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let harness = try Harness(widget("""
        onAction: function () {
          host.screen.record({ x: 0, y: 0, width: 200, height: 100 }, "\(path)").then(function (p) { count = p; }, function (e) { count = e.message; });
        },
        """), uses: ["screen"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("record", .null)
        #expect(try await harness.text() == path)
        try await Task.sleep(for: .seconds(1))
        harness.runtime.stop()
        let movie = AVURLAsset(url: URL(fileURLWithPath: path))
        var seconds = 0.0
        for _ in 0..<50 where seconds == 0 {
            try await Task.sleep(for: .milliseconds(100))
            seconds = await (try? movie.load(.duration).seconds) ?? 0
        }
        #expect(seconds > 0.5)
        let video = try #require(await movie.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size.width >= 200 && size.width == 2 * size.height)
    }
}
