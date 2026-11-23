import AppKit
@testable import gary
import GaryCore
import SwiftUI
import Testing

@MainActor
struct SliderNodeTests {
    private let theme: Theme

    init() throws {
        theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
    }

    @Test func `a drag holds the dragged value against updates and releases it once with its own rate`() {
        var drag = SliderDrag()
        #expect(drag.edit(true, shown: 0.2, rate: 0.5, at: 0) == nil)
        #expect(drag.held == Node.Fraction(0.2, at: 0))
        drag.move(to: 0.4, at: 10)
        drag.fractionChanged()
        drag.move(to: 0.6, at: 20)
        #expect(drag.held == Node.Fraction(0.6, at: 20))
        #expect(drag.edit(false, shown: 0.3, rate: 0.5, at: 30) == 0.6)
        #expect(drag.held == Node.Fraction(0.6, rate: 0.5, at: 30))
        drag.fractionChanged()
        #expect(drag.held == nil)
    }

    @Test func `a fraction with a rate advances from its value by the time since at and stays within 0 and 1`() {
        let fraction = Node.Fraction(0.2, rate: 0.25, at: 10000)
        #expect(fraction.value(at: 12000) == 0.7)
        #expect(fraction.value(at: 20000) == 1)
        #expect(Node.Fraction(0.2, rate: -0.25, at: 10000).value(at: 12000) == 0)
        #expect(Node.Fraction(0.2).value(at: 12000) == 0.2)
    }

    @Test func `a progress bar with a rate draws its value at the current time`() throws {
        func filled(_ fields: String) throws -> Int {
            let node = try Node.parse(JSON.parse(##"{"type":"progress","width":100,"height":4,"color":"#ff0000",\##(fields)}"##))
            let renderer = ImageRenderer(content: NodeView(node: node, theme: theme))
            renderer.scale = 1
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            return (0..<bitmap.pixelsWide).count { (bitmap.colorAt(x: $0, y: 2)?.alphaComponent ?? 0) > 0.9 }
        }
        #expect(try filled(#""value":0.2"#) == 20)
        #expect(try filled(#""value":0.2,"rate":0.25,"at":0"#) == 100)
        #expect(try filled(#""value":0.2,"rate":-0.25,"at":0"#) == 0)
    }
}
