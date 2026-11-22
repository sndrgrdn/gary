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

    @Test func `a drag sends the slider's action as it moves and its release action once with the final value`() throws {
        var sent: [ActionEvent] = []
        let node = try Node.parse(JSON.parse(#"{"type":"slider","value":0,"action":"seek","release":"seek-end","width":200}"#))
        let view = TreeHostingView(
            tree: MountedTree(root: node, theme: theme),
            onAction: { sent.append($0) },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: x, y: 20), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
            )
        }
        for (type, x) in [(NSEvent.EventType.leftMouseDown, 40.0), (.leftMouseDragged, 80), (.leftMouseDragged, 120), (.leftMouseUp, 120)] {
            try window.sendEvent(#require(event(type, x)))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        window.close()
        let names = sent.map(\.name)
        #expect(names.last == "seek-end")
        #expect(names.count(where: { $0 == "seek-end" }) == 1)
        #expect(names.dropLast().allSatisfy { $0 == "seek" } && names.count > 2)
        #expect(sent.last?.payload == sent.dropLast().last?.payload)
    }

    @Test func `a progress bar with a rate has advanced from its value by the time since at`() throws {
        func filled(_ fields: String) throws -> Int {
            let node = try Node.parse(JSON.parse(##"{"type":"progress","width":100,"height":4,"color":"#ff0000",\##(fields)}"##))
            let renderer = ImageRenderer(content: NodeView(node: node, theme: theme))
            renderer.scale = 1
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            return (0..<bitmap.pixelsWide).count { (bitmap.colorAt(x: $0, y: 2)?.alphaComponent ?? 0) > 0.9 }
        }
        let now = Date().timeIntervalSince1970 * 1000
        #expect(try filled(#""value":0.2"#) == 20)
        #expect(try (69...71).contains(filled(#""value":0.2,"rate":0.25,"at":\#(now - 2000)"#)))
        #expect(try filled(#""value":0.2,"rate":-0.25,"at":\#(now - 2000)"#) == 0)
    }
}
