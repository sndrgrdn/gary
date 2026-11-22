import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct SliderNodeTests {
    @Test func `a drag sends the slider's action as it moves and its release action once when it ends`() throws {
        let theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        var sent: [String] = []
        let node = try Node.parse(JSON.parse(#"{"type":"slider","value":0,"action":"seek","release":"seek-end","width":200}"#))
        let view = TreeHostingView(
            tree: MountedTree(root: node, theme: theme),
            onAction: { sent.append($0.name) },
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
        #expect(sent.last == "seek-end")
        #expect(sent.count(where: { $0 == "seek-end" }) == 1)
        #expect(sent.dropLast().allSatisfy { $0 == "seek" } && sent.count > 2)
    }
}
