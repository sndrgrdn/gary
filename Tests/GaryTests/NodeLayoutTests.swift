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

    private nonisolated static let inkSamples = [
        ("JetBrainsMono Nerd Font", "\u{F00AF}"),
        ("JetBrainsMono Nerd Font", "\u{F0928}"),
        ("Snell Roundhand", "f"),
    ]
    .filter { NSFontManager.shared.availableFontFamilies.contains($0.0) }

    private func text(_ text: String, family: String, fields: String = "") throws -> NodeView {
        let base = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json")))
        let theme = try Theme.parse(
            base,
            palette: Palette(nil, system: .dark),
            override: JSON.parse(#"{"fonts":{"body":{"family":"\#(family)","size":13,"weight":"regular"}}}"#),
        )
        return try NodeView(node: Node.parse(JSON.parse(#"{"type":"text",\#(fields)"text":\#(JSON.string(text).text)}"#)), theme: theme)
    }

    private func width(_ text: String, family: String) throws -> CGFloat {
        try NSHostingView(rootView: self.text(text, family: family)).fittingSize.width
    }

    private func line(_ text: String, family: String) throws -> (ink: CGRect, advance: Double) {
        let font = try #require(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return (CTLineGetBoundsWithOptions(line, .useGlyphPathBounds), CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test(arguments: inkSamples)
    func `a text node's frame holds the ink of glyphs that outrun their advance`(family: String, text: String) throws {
        let (ink, advance) = try line(text, family: family)
        #expect(try width(text, family: family) >= max(ink.maxX, advance) - min(ink.minX, 0))
    }

    @Test func `plain text keeps its typographic width`() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let plain = NSHostingView(rootView: Text(verbatim: "Wi-Fi 100%").font(Font(font as CTFont)).fixedSize()).fittingSize.width
        #expect(try width("Wi-Fi 100%", family: "system") == plain)
    }

    @Test(arguments: inkSamples.filter { $0.0 == "JetBrainsMono Nerd Font" })
    func `a glyph in a fixed-width centred slot draws whole, centred by its ink`(family: String, glyph: String) throws {
        let view = try NSHostingView(rootView: text(glyph, family: family, fields: #""width":27,"align":"center","#))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let inked = (0..<bitmap.pixelsWide)
            .filter { x in (0..<bitmap.pixelsHigh).contains { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1 } }
        let left = try #require(inked.first)
        let right = try #require(inked.last)
        let scale = Double(bitmap.pixelsWide) / view.bounds.width
        #expect(view.bounds.width == 27)
        #expect(try Double(right + 1 - left) / scale >= line(glyph, family: family).ink.width - 0.5)
        #expect(abs(Double(left + right + 1) / 2 / scale - 13.5) <= 0.5)
    }
}
