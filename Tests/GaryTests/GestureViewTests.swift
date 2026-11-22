import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct GestureViewTests {
    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)

    private func gestureView(_ frame: CGRect, _ actions: [Node.Gesture: String]) -> GestureView {
        let view = GestureView(frame: frame)
        view.actions = actions
        window.contentView?.addSubview(view)
        return view
    }

    private func mouse(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        )
    }

    private func middle() -> NSEvent? {
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)
        return event.flatMap(NSEvent.init(cgEvent:))
    }

    private func scroll() -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:))
    }

    @Test func `claims the gestures it has actions for and lets left clicks and hover through`() {
        let view = gestureView(CGRect(x: 0, y: 0, width: 200, height: 100), [.click: "open", .rightClick: "menu", .scroll: "volume"])
        let inside = CGPoint(x: 50, y: 50)
        #expect(view.hitTest(inside, event: mouse(.rightMouseDown)) === view)
        #expect(view.hitTest(inside, event: scroll()) === view)
        #expect(view.hitTest(inside, event: mouse(.leftMouseDown)) == nil)
        #expect(view.hitTest(inside, event: mouse(.mouseMoved)) == nil)
        #expect(view.hitTest(inside, event: middle()) == nil)
        #expect(view.hitTest(CGPoint(x: 250, y: 50), event: mouse(.rightMouseDown)) == nil)
        view.actions[.middleClick] = "close"
        #expect(view.hitTest(inside, event: middle()) === view)
    }

    @Test func `the innermost node with an action for the gesture takes it`() {
        let outer = gestureView(CGRect(x: 0, y: 0, width: 200, height: 100), [.rightClick: "outer", .scroll: "outer"])
        let inner = gestureView(CGRect(x: 10, y: 10, width: 40, height: 20), [.rightClick: "inner"])
        let point = CGPoint(x: 20, y: 20)
        #expect(outer.hitTest(point, event: mouse(.rightMouseDown)) === inner)
        #expect(outer.hitTest(point, event: scroll()) === outer)
        #expect(outer.hitTest(CGPoint(x: 100, y: 80), event: mouse(.rightMouseDown)) === outer)
    }

    private func scrolled(_ node: String) throws -> (sent: [String], offset: Double) {
        let theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        var sent: [String] = []
        let host = try TreeHostingView(
            tree: MountedTree(root: Node.parse(JSON.parse(node)), theme: theme),
            onAction: { sent.append($0.name) },
            onDismiss: { sent.append("dismiss") },
        )
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let list = try #require(host.descendants(NSScrollView.self).first)
        let point = list.convert(CGPoint(x: 10, y: 10), to: nil)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        wheel.location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        let event = try #require(NSEvent(cgEvent: wheel))
        let catcher = try #require(host.descendants(GestureView.self).first)
        try #require(catcher.hitTest(catcher.superview?.convert(point, from: nil) ?? point, event: event)).scrollWheel(with: event)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        return (sent, list.contentView.bounds.origin.y)
    }

    private let rows = (0..<40).map { #"{"type":"text","key":"\#($0)","text":"row \#($0)"}"# }.joined(separator: ",")

    @Test func `a scroll node with a scroll action scrolls and sends the action`() throws {
        let result = try scrolled(#"{"type":"scroll","height":100,"scrollAction":"wheel","children":[\#(rows)]}"#)
        #expect(result.sent == ["wheel"])
        #expect(result.offset > 0)
    }

    @Test func `a node with a scroll action inside a scroll node takes the scroll from it`() throws {
        let result = try scrolled(#"{"type":"scroll","height":100,"children":[{"type":"column","scrollAction":"wheel","children":[\#(rows)]}]}"#)
        #expect(result.sent == ["wheel"])
        #expect(result.offset == 0)
    }
}
