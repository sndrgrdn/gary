import AppKit
@testable import gary
import GaryCore
import Testing

struct ClipboardTests {
    @Test func `an image or files written to the clipboard read back as an image or files`() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("gary-test-\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "gary-clipboard-\(UUID().uuidString)")
        defer {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pixel = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        )?.representation(using: .png, properties: [:]))
        let image = folder.appending(path: "dot.png")
        try pixel.write(to: image)

        let written = try writeClipboard(.image(path: image.path), to: board)
        #expect(Set(board.types ?? []).isSuperset(of: [.png, .tiff]))
        let read = try readClipboard(board)
        #expect(read["count"] == written["count"])
        let copy = try #require(read["image"]?.string)
        #expect(NSImage(contentsOfFile: copy)?.size == NSSize(width: 2, height: 2))

        _ = try writeClipboard(.files(paths: [image.path, folder.path]), to: board)
        #expect(try readClipboard(board)["files"] == .array([.string(image.path), .string(folder.path)]))

        #expect(throws: HostFailure.self) { try writeClipboard(.files(paths: [folder.appending(path: "gone.txt").path]), to: board) }
        #expect(throws: HostFailure.self) { try writeClipboard(.image(path: folder.path), to: board) }
        #expect(try readClipboard(board)["files"] == .array([.string(image.path), .string(folder.path)]))
    }
}
