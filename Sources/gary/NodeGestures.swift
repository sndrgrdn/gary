import AppKit
import GaryCore
import SwiftUI

struct ActionEvent {
    let name: String
    let payload: JSON
    let origin: CGRect?
}

final class GestureAnchor {
    weak var view: GestureView?
}

final class GestureView: NSView {
    var actions: [Node.Gesture: String] = [:]
    var scrolls = false
    var handler: ActionHandler?
    weak var tooltipPanel: TooltipPanel?
    var tooltip: String? {
        didSet {
            if tooltip != oldValue {
                tooltipPanel?.refresh(self)
                if pointerInside {
                    hover()
                }
            }
        }
    }

    private var pointerInside = false

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
        let claiming = (window?.contentView ?? self).descendants(GestureView.self).filter { view in
            view.actions[gesture] != nil && view.convert(view.bounds, to: nil).contains(location)
        }
        return claiming.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } ?? self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with _: NSEvent) {
        pointerInside = true
        hover()
    }

    override func mouseExited(with _: NSEvent) {
        pointerInside = false
        tooltipPanel?.hide(for: self)
    }

    private func hover() {
        if tooltip != nil {
            tooltipPanel?.hover(self)
        }
    }

    override func rightMouseDown(with _: NSEvent) {
        send(.rightClick, .null)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            send(.middleClick, .null)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        send(.scroll, event.scrollEvent)
        if scrolls {
            let scrollView = (window?.contentView ?? self).descendants(NSScrollView.self).last { view in
                view.convert(view.bounds, to: nil).contains(event.locationInWindow)
            }
            scrollView?.scrollWheel(with: event)
        }
    }

    func send(_ gesture: Node.Gesture, _ payload: JSON) {
        guard let action = actions[gesture] else { return }
        handler?(ActionEvent(name: action, payload: payload, origin: window?.convertToScreen(convert(bounds, to: nil))))
    }
}

extension NSView {
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        [self].compactMap { $0 as? View } + subviews.flatMap { $0.descendants(type) }
    }
}

struct GestureCatcher: NSViewRepresentable {
    let actions: [Node.Gesture: String]
    let scrolls: Bool
    let tooltip: String?
    let anchor: GestureAnchor
    @Environment(\.nodeAction) private var perform
    @Environment(\.tooltipPanel) private var tooltipPanel

    func makeNSView(context _: Context) -> GestureView {
        GestureView()
    }

    func updateNSView(_ view: GestureView, context _: Context) {
        view.actions = actions
        view.scrolls = scrolls
        view.handler = perform
        view.tooltipPanel = tooltipPanel
        view.tooltip = tooltip
        anchor.view = view
    }

    static func dismantleNSView(_ view: GestureView, coordinator _: ()) {
        view.tooltipPanel?.hide(for: view)
    }
}
