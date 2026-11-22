import CoreGraphics
@testable import gary
import Testing

struct TrayTests {
    private func image(width: Int, height: Int, ink: [CGRect]) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        for rect in ink {
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        return try #require(context.makeImage())
    }

    @Test func `ink bounds hold every visible pixel in top left pixel coordinates`() throws {
        let icon = try image(width: 40, height: 30, ink: [CGRect(x: 6, y: 4, width: 10, height: 12), CGRect(x: 30, y: 20, width: 2, height: 3)])
        let ink = try #require(inkBounds(icon))
        #expect(ink == CGRect(x: 6, y: 4, width: 26, height: 19))
        #expect(icon.cropping(to: ink).map { [$0.width, $0.height] } == [26, 19])
    }

    @Test func `a fully transparent capture has no ink`() throws {
        #expect(try inkBounds(image(width: 40, height: 30, ink: [])) == nil)
    }
}
