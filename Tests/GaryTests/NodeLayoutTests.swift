import AppKit
@testable import gary
import GaryCore
import SwiftUI
import Testing

@MainActor
struct NodeLayoutTests {
    private static let theme = try? Theme.parse(
        JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json"))),
        palette: Palette(nil, system: .dark),
    )

    private func size(_ json: String, inBar: Bool = false, width: CGFloat? = nil) throws -> CGSize {
        let theme = try #require(Self.theme)
        let view = try NodeView(node: Node.parse(JSON.parse(json)), theme: inBar ? theme.inBar : theme)
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    private func columns(_ view: some View) throws -> [NSColor] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        return (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: 0) }
    }

    @Test func `a row given its ideal width lays out nested rows without wrapping their text`() throws {
        let nested = #"""
        {"type":"row","gap":6,"children":[
          {"type":"row","gap":6,"children":[{"type":"text","text":"CPU"},{"type":"chart","width":40,"height":12,"series":[{"values":[1,4,2]}]},{"type":"text","text":"21%"}]},
          {"type":"text","text":"MEM 50%"}
        ]}
        """#
        let ideal = try size(nested)
        #expect(try size(nested, width: ideal.width) == ideal)
        #expect(try size(nested, width: ideal.width + 30).height == ideal.height)
    }

    @Test func `a row too narrow for its children shrinks the widest first`() throws {
        let row = RowLayout(spacing: 0) {
            Color(.sRGB, red: 1, green: 0, blue: 0).frame(minWidth: 10, idealWidth: 100, maxWidth: 100)
            Color(.sRGB, red: 0, green: 0, blue: 1).frame(minWidth: 10, idealWidth: 30, maxWidth: 30)
        }
        let pixels = try columns(row.frame(width: 100, height: 1))
        #expect(pixels.prefix(70).allSatisfy { $0.redComponent > 0.9 && $0.blueComponent < 0.1 })
        #expect(pixels.suffix(30).allSatisfy { $0.blueComponent > 0.9 && $0.redComponent < 0.1 })
    }

    @Test func `a row gives the width its wrapped text leaves unused to its spacers`() throws {
        let row = RowLayout(spacing: 0) {
            Text("a long line of text that cannot fit")
            HStack(spacing: 0) { Spacer(minLength: 0) }
            Color(.sRGB, red: 0, green: 0, blue: 1).frame(width: 10)
        }
        let pixels = try columns(row.frame(width: 100))
        #expect(pixels.suffix(10).allSatisfy { $0.blueComponent > 0.9 && $0.redComponent < 0.1 })
    }

    @Test func `text wraps in a surface but stays on one line in the bar or within its lines`() throws {
        let text = #"{"type":"text","text":"a long line of text that cannot fit"}"#
        let line = try size(text).height
        #expect(try size(text, width: 60).height > line * 2)
        let barLine = try size(text, inBar: true).height
        #expect(try size(text, inBar: true, width: 60).height == barLine)
        #expect(try size(#"{"type":"text","lines":2,"text":"a long line of text that cannot fit"}"#, width: 60).height == line * 2)
        #expect(try size(#"{"type":"text","lines":2,"text":"a long line of text that cannot fit"}"#, inBar: true, width: 60).height
            == barLine * 2)
    }

    @Test func `text with its own width spills on one line unless it truncates or wraps to its lines`() throws {
        func drawn(_ fields: String) throws -> CGSize {
            try size(#"{"type":"row","children":[{"type":"text","width":60,\#(fields)"text":"a long line of text that cannot fit"}]}"#)
        }
        let line = try size(#"{"type":"text","text":"a"}"#).height
        #expect(try drawn("").height == line)
        #expect(try drawn(#""truncate":"tail","#) == CGSize(width: 60, height: line))
        #expect(try drawn(#""lines":2,"#) == CGSize(width: 60, height: line * 2))
    }
}
