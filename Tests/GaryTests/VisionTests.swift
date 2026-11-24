import AppKit
import CoreImage.CIFilterBuiltins
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
    var text = try await harness.text()
    while text == "0" {
        text = try await harness.text()
    }
    return text
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
        let text = try await result(harness)
        #expect(text == "\"Gary reads this\"")
        harness.runtime.stop()
    }

    @Test func `read text rejects A file that is missing`() async throws {
        let harness = try Harness(reader("readText(path)"), uses: ["vision"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("/tmp/gary-vision-missing.png", .null)
        #expect(try await harness.text() == "host.vision.readText: /tmp/gary-vision-missing.png is not a readable image")
        harness.runtime.stop()
    }

    @Test func `read codes resolves with the symbology and payload of each QR code`() async throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://gary.test/scan".utf8)
        let code = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let png = try #require(CIContext().pngRepresentation(of: code, format: .RGBA8, colorSpace: srgb))
        let path = FileManager.default.temporaryDirectory.appending(path: "gary-vision-\(UUID().uuidString).png").path
        try png.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let harness = try Harness(reader("readCodes(path)"), uses: ["vision"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform(path, .null)
        #expect(try await result(harness) == #"[{"payload":"https://gary.test/scan","symbology":"qr"}]"#)
        harness.runtime.stop()
    }
}
