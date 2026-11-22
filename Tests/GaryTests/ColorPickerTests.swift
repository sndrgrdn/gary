import AppKit
@testable import gary
import Testing

struct ColorPickerTests {
    @Test func `a picked colour reads as sRGB hex whatever space the screen sampled it in`() {
        #expect(sRGBHex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#ff8000")
        #expect(sRGBHex(NSColor.white) == "#ffffff")
        #expect(sRGBHex(NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 1)) == "#000000")
        #expect(sRGBHex(NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)) == "#ff0000")
        #expect(sRGBHex(NSColor(displayP3Red: 0.5, green: 0.5, blue: 0.5, alpha: 1)) == "#808080")
    }
}
