import AppKit
import GaryCore
import SwiftUI

final class GestureView: NSView {
    var actions: [Node.Gesture: String] = [:]
    var perform: ActionHandler?

    static func gesture(of event: NSEvent) -> Node.Gesture? {
        switch event.type {
        case .rightMouseDown: .rightClick
        case .otherMouseDown: event.buttonNumber == 2 ? .middleClick : nil
        case .scrollWheel: .scroll
        default: nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, event: NSApp.currentEvent)
    }

    func hitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        guard let event, let gesture = Self.gesture(of: event), actions[gesture] != nil, super.hitTest(point) != nil else { return nil }
        let location = superview?.convert(point, to: nil) ?? point
        let claiming = (window?.contentView ?? self).gestureViews.filter { view in
            view.actions[gesture] != nil && view.convert(view.bounds, to: nil).contains(location)
        }
        return claiming.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } ?? self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with _: NSEvent) {
        fire(.rightClick, .null)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            fire(.middleClick, .null)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        fire(.scroll, event.scrollEvent)
    }

    private func fire(_ gesture: Node.Gesture, _ payload: JSON) {
        if let action = actions[gesture] {
            perform?(action, payload)
        }
    }
}

private extension NSView {
    var gestureViews: [GestureView] {
        [self].compactMap { $0 as? GestureView } + subviews.flatMap(\.gestureViews)
    }
}

struct GestureCatcher: NSViewRepresentable {
    let actions: [Node.Gesture: String]
    @Environment(\.nodeAction) private var perform

    func makeNSView(context _: Context) -> GestureView {
        GestureView()
    }

    func updateNSView(_ view: GestureView, context _: Context) {
        view.actions = actions
        view.perform = perform
    }
}
