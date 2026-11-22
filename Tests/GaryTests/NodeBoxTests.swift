import Foundation
@testable import gary
import GaryCore
import SwiftUI
import Testing

struct NodeBoxTests {
    private static let theme = try? Theme.parse(
        JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json"))),
        palette: Palette(nil, system: .dark),
    )

    private func box(_ content: Node.Content, action: String? = "open", _ props: StyleProps = StyleProps()) throws -> NodeBox {
        let theme = try #require(Self.theme)
        let node = Node(content, actions: action.map { [.click: $0] } ?? [:], props: props)
        return NodeBox(theme.resolve(nil, props), node)
    }

    @Test func `a text node takes the size padding background action and alignment of its look`() throws {
        let box = try box(.text("hi"), StyleProps(width: 40, height: 20, padding: Insets(4), align: .trailing, background: "#ff0000", clip: true))
        #expect(box.width == 40)
        #expect(box.height == 20)
        #expect(box.padding == Insets(4))
        #expect(box.background == RGBA(hex: "#ff0000").map(ResolvedPaint.color))
        #expect(box.action == "open")
        #expect(box.alignment == Alignment(horizontal: .trailing, vertical: .center))
        #expect(box.clip)
    }

    @Test func `columns and stacks align to the top`() throws {
        #expect(try box(.column([])).alignment == .topLeading)
        #expect(try box(.stack([])).alignment == .topLeading)
        #expect(try box(.row([])).alignment == Alignment(horizontal: .leading, vertical: .center))
    }

    @Test func `a scroll node leaves its height padding and clicks to the scroll view`() throws {
        let box = try box(.scroll([], reveal: nil), StyleProps(width: 40, height: 100, padding: Insets(8)))
        #expect(box.width == 40)
        #expect(box.height == nil)
        #expect(box.padding == Insets(0))
        #expect(box.action == nil)
        #expect(box.alignment == .topLeading)
    }

    @Test func `an image is 16 square by default, square from one side, centred, and clipped when it fills`() throws {
        let plain = try box(.image("/a.png"))
        #expect(plain.width == 16)
        #expect(plain.height == 16)
        #expect(plain.alignment == .center)
        #expect(!plain.clip)
        let wide = try box(.image("/a.png"), StyleProps(width: 30))
        #expect(wide.width == 30)
        #expect(wide.height == 30)
        #expect(try box(.image("/a.png"), StyleProps(fit: .fill)).clip)
        #expect(try box(.image("/a.png"), StyleProps(align: .leading)).alignment == .leading)
    }

    @Test func `sliders and inputs take a default width and handle their own clicks`() throws {
        let slider = try box(.slider(0.5, release: nil))
        #expect(slider.width == 120)
        #expect(slider.action == nil)
        let input = try box(.input(Node.Input(value: "")))
        #expect(input.width == 240)
        #expect(input.action == nil)
        #expect(try box(.slider(0.5, release: nil), StyleProps(width: 80)).width == 80)
    }

    @Test func `a progress bar is 120 by 6 by default and paints no box background`() throws {
        let box = try box(.progress(0.5), StyleProps(background: "#ff0000"))
        #expect(box.width == 120)
        #expect(box.height == 6)
        #expect(box.background == nil)
    }

    @Test func `icons centre unless aligned`() throws {
        #expect(try box(.icon("star")).alignment == .center)
        #expect(try box(.icon("star"), StyleProps(align: .trailing)).alignment == .trailing)
    }
}
