import Foundation
@testable import gary
import GaryCore
import SwiftUI
import Testing

@MainActor
struct NodeDrawingRenderTests {
    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private struct Bitmap {
        let width: Int
        let bytes: [UInt8]

        subscript(x: Int, y: Int) -> Pixel {
            let index = (y * width + x) * 4
            return Pixel(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2], alpha: bytes[index + 3])
        }
    }

    private static let theme = try? Theme.parse(
        JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json"))),
        palette: Palette(nil, system: .dark),
    )

    private func render(_ json: String) throws -> Bitmap {
        let node = try Node.parse(JSON.parse(json))
        let theme = try #require(Self.theme)
        let renderer = ImageRenderer(content: NodeView(node: node, theme: theme))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return try bitmap(image)
    }

    private func bitmap(_ image: CGImage) throws -> Bitmap {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Bitmap(width: image.width, bytes: bytes)
    }

    private func isRed(_ pixel: Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 40 && pixel.blue < 40 && pixel.alpha > 200
    }

    private func isBlue(_ pixel: Pixel) -> Bool {
        pixel.blue > 200 && pixel.red < 40 && pixel.green < 40 && pixel.alpha > 200
    }

    @Test func `a shape fills its path scaled from the view box`() throws {
        let image = try render(##"{"type":"shape","width":40,"height":40,"viewBox":[20,20],"paths":[{"d":"M0 0 L20 0 L0 20 Z","fill":"#ff0000"}]}"##)
        #expect(isRed(image[6, 6]))
        #expect(isRed(image[30, 4]))
        #expect(image[34, 34].alpha == 0)
    }

    @Test func `a linear gradient background runs from its first colour to its last`() throws {
        let across = try render(##"{"type":"row","width":60,"height":10,"background":{"gradient":"linear","colors":["#ff0000","#0000ff"]}}"##)
        #expect(isRed(across[0, 5]) && isBlue(across[59, 5]))
        #expect(across[30, 5].red > 60 && across[30, 5].blue > 60)
        let down =
            try render(##"{"type":"row","width":10,"height":60,"background":{"gradient":"linear","colors":["#ff0000","#0000ff"],"angle":90}}"##)
        #expect(isRed(down[5, 0]) && isBlue(down[5, 59]))
    }

    @Test func `a trimmed stroke draws only its part of the path`() throws {
        let ring = "M20 4 A16 16 0 1 1 19.99 4"
        let image =
            try render(##"{"type":"shape","width":40,"height":40,"paths":[{"d":"\##(ring)","stroke":"#ff0000","lineWidth":4,"trim":[0,0.25]}]}"##)
        #expect(isRed(image[31, 9]))
        #expect(isRed(image[35, 17]))
        #expect(image[4, 20].alpha == 0)
        #expect(image[20, 36].alpha == 0)
        #expect(image[20, 20].alpha == 0)
    }
}
