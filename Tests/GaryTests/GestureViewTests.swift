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
}
