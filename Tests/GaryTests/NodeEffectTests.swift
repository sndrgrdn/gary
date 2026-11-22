import AppKit
@testable import gary
import GaryCore
import SwiftUI
import Testing

@MainActor
struct NodeEffectTests {
    private static let theme = try? Theme.parse(
        JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json"))),
        palette: Palette(nil, system: .dark),
    )

    private func pixels(_ view: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 160, height: 120).background(Color.white))
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private func expectSame(_ actual: some View, _ expected: some View) throws {
        let actual = try pixels(actual)
        let expected = try pixels(expected)
        #expect(actual.count == expected.count)
        #expect(!zip(actual, expected).contains(where: { abs(Int($0) - Int($1)) > 2 }))
        #expect(expected.contains { $0 < 200 })
    }

    private func effects(_ props: StyleProps) throws -> VisualEffects {
        let theme = try #require(Self.theme)
        return VisualEffects(theme.resolve(nil, props), Node(.text("x"), props: props))
    }

    private var shape: some View {
        HStack(spacing: 0) { Color.red.frame(width: 30); Color.blue.frame(width: 20) }.frame(height: 24)
    }

    @Test func `a node's scale rotation blur opacity blend and offset draw as SwiftUI's own effects`() throws {
        let props = StyleProps(opacity: 0.7, x: 9, y: -1, scale: 1.4, rotation: 30, blur: 1, blend: .multiply)
        try expectSame(
            shape.modifier(effects(props)),
            shape.scaleEffect(1.4).rotationEffect(.degrees(30)).blur(radius: 1).opacity(0.7).blendMode(.multiply).offset(x: 9, y: -1),
        )
    }

    @Test func `a loop's scale rotation opacity and offset apply outside the node's own effects`() throws {
        let loop = Loop([.scale: .init(1.5, 1.5), .rotation: .init(20, 20), .opacity: .init(0.8, 0.8), .x: .init(-6, -6), .y: .init(5, 5)])
        let props = StyleProps(x: 10, y: 2, scale: 0.8, rotation: -15, loop: loop)
        try expectSame(
            shape.modifier(effects(props)),
            shape.scaleEffect(0.8).rotationEffect(.degrees(-15))
                .scaleEffect(1.5).rotationEffect(.degrees(20)).opacity(0.8).offset(x: -6, y: 5)
                .offset(x: 10, y: 2),
        )
    }

    @Test(arguments: [Alignment.leading, .center, .trailing, .topLeading, .top, .topTrailing])
    func `minWidth sizes and places a node as a minimum width frame does`(alignment: Alignment) throws {
        let short = Text("hi").background(Color.red)
        let long = Text("a longer line of text that wraps").background(Color.red)
        let flexible = Color.red.frame(height: 10)
        let wide = Color.red.frame(width: 100, height: 6)
        func layouts(_ wrap: @escaping (AnyView) -> AnyView) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                wrap(AnyView(short)).frame(width: 140, height: 30)
                wrap(AnyView(short)).fixedSize()
                wrap(AnyView(long)).frame(width: 40)
                HStack(spacing: 0) { wrap(AnyView(long)); Color.green.frame(width: 20, height: 4) }.frame(width: 150)
                wrap(AnyView(flexible)).frame(width: 120)
                wrap(AnyView(flexible)).fixedSize()
                wrap(AnyView(wide)).frame(width: 40)
            }
        }
        try expectSame(
            layouts { view in AnyView(MinWidth(minWidth: 60, alignment: alignment) { view }.background(Color.yellow)) },
            layouts { AnyView($0.frame(minWidth: 60, alignment: alignment).background(Color.yellow)) },
        )
        try expectSame(
            layouts { view in AnyView(MinWidth(minWidth: nil, alignment: alignment) { view }.background(Color.yellow)) },
            layouts { AnyView($0.background(Color.yellow)) },
        )
    }

    @Test func `a spacer node grows only along its row or column`() throws {
        let theme = try #require(Self.theme)
        let tree = try Node.parse(JSON.parse(#"""
        {"type":"column","children":[
          {"type":"row","rightAction":"row","children":[{"type":"text","text":"a"},{"type":"spacer"},{"type":"text","text":"b"}]},
          {"type":"column","rightAction":"column","children":[{"type":"text","text":"c"},{"type":"spacer"}]}
        ]}
        """#))
        let host = TreeHostingView(
            tree: MountedTree(root: tree, theme: theme),
            onAction: { _ in Issue.record("unexpected action") },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let frames = host.descendants(GestureView.self).map { ($0.actions[.rightClick], $0.frame.size) }
        let row = try #require(frames.first { $0.0 == "row" }?.1)
        let column = try #require(frames.first { $0.0 == "column" }?.1)
        #expect(row.height < 40)
        #expect(row.width > 250)
        #expect(column.width < 40)
        #expect(column.height > 200)
    }
}
