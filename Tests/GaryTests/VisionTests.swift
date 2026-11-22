import AppKit
@testable import gary
import Testing

private func writePNG(_ draw: @escaping () -> Void) throws -> String {
    let size = CGSize(width: 800, height: 200)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        draw()
        return true
    }
    let path = FileManager.default.temporaryDirectory.appending(path: "gary-vision-\(UUID().uuidString).png").path
    guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        throw RenderError("cannot draw the image")
    }
    try png.write(to: URL(fileURLWithPath: path))
    return path
}

private func reader(_ call: String) -> String {
    widget("""
    onAction: function (path) {
      host.vision.\(call).then(function (result) { count = JSON.stringify(result); }, function (error) { count = error.message; });
    },
    """)
}

private func result(_ harness: Harness) async throws -> String {
    let start = Date()
    while Date().timeIntervalSince(start) < 60 {
        if let text = try? await harness.text(), text != "0" {
            return text
        }
    }
    throw RenderError("no result in 60 seconds")
}

struct VisionTests {
    @Test func `read text resolves with the text in an image file`() async throws {
        let path = try writePNG {
            NSAttributedString(string: "Gary reads this", attributes: [.font: NSFont.systemFont(ofSize: 64)]).draw(at: CGPoint(x: 40, y: 60))
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let harness = try Harness(reader("readText(path)"), uses: ["vision"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform(path, .null)
        #expect(try await result(harness) == "\"Gary reads this\"")
        harness.runtime.stop()
    }

    @Test func `read text rejects A file that is missing`() async throws {
        let harness = try Harness(reader("readText(path)"), uses: ["vision"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("/tmp/gary-vision-missing.png", .null)
        #expect(try await harness.text() == "host.vision.readText: /tmp/gary-vision-missing.png is not a readable image")
        harness.runtime.stop()
    }
}
