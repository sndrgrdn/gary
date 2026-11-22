import AppKit
import Foundation
@testable import gary
import GaryCore
import Metal
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

    @Test func `a chart with labels draws them along its x axis in the node's color`() throws {
        func redPixels(_ labels: String) throws -> Int {
            let image = try render(##"""
            {"type":"chart","width":120,"height":40,"color":"#ff0000",\##(labels)"series":[{"values":[1,3,2,4],"color":"#0000ff"}]}
            """##)
            return (0..<120).reduce(0) { count, x in count + (0..<40).count { isRed(image[x, $0]) } }
        }
        #expect(try redPixels("") == 0)
        #expect(try redPixels(#""labels":["18","","20","21"],"#) > 10)
    }

    @Test func `an image with its own color draws its shape filled with that color`() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "gary-tint-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try #require(CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        let drawn = try #require(context.makeImage())
        try #require(NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:])).write(to: file)
        let plain = try render(##"{"type":"image","path":"\##(file.path)","width":20,"height":20}"##)
        #expect(plain[4, 10] == Pixel(red: 0, green: 0, blue: 0, alpha: 255))
        let tinted = try render(##"{"type":"image","path":"\##(file.path)","width":20,"height":20,"color":"#ff0000"}"##)
        #expect(isRed(tinted[4, 10]))
        #expect(tinted[15, 10].alpha == 0)
    }

    @Test(.enabled(if: ShaderProgram.device != nil, "this Mac has no Metal device"))
    func `a shader draws its function into the frame in points from the top left`() throws {
        let program = try ShaderProgram(source: """
        half4 halves(float2 position, float2 size, float time, constant float *args, uint count) {
            if (position.y < size.y / 2) return half4(args[0], args[1], args[2], 1);
            return half4(0, 0, 1, count == 3 ? 0.5 : 1);
        }
        """, function: "halves")
        let device = try #require(ShaderProgram.device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderProgram.pixelFormat, width: 16, height: 16, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let buffer = try #require(ShaderProgram.queue?.makeCommandBuffer())
        let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
        program.encode(encoder, size: CGSize(width: 8, height: 8), scale: 2, time: 0, args: [0, 1, 0])
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        texture.getBytes(&bytes, bytesPerRow: 16 * 4, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes.swapAt(index, index + 2)
        }
        let pixels = Bitmap(width: 16, bytes: bytes)
        #expect(pixels[3, 3] == Pixel(red: 0, green: 255, blue: 0, alpha: 255))
        #expect(pixels[12, 12] == Pixel(red: 0, green: 0, blue: 128, alpha: 128))
    }

    @Test(.enabled(if: ShaderProgram.device != nil, "this Mac has no Metal device"))
    func `a shader that does not compile throws the compiler's message`() {
        #expect {
            try ShaderProgram(source: "half4 broken(float2 position) { return nope; }", function: "broken")
        } throws: { error in
            error.localizedDescription.contains("nope")
        }
    }
}
