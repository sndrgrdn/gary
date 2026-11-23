import AppKit
import GaryCore
import SwiftUI

typealias ActionHandler = (ActionEvent) -> Void

private struct ActionKey: EnvironmentKey {
    static let defaultValue: ActionHandler? = nil
}

extension EnvironmentValues {
    var nodeAction: ActionHandler? {
        get { self[ActionKey.self] }
        set { self[ActionKey.self] = newValue }
    }
}

struct ActionEvent {
    let name: String
    let payload: JSON
    let origin: CGRect?
    var gesture: Node.Gesture?
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
        return Self.claimant(of: gesture, at: superview?.convert(point, to: nil) ?? point, in: window?.contentView ?? self) ?? self
    }

    static func claimant(of gesture: Node.Gesture, at location: CGPoint, in root: NSView) -> GestureView? {
        let claiming = root.descendants(GestureView.self).filter { view in
            view.actions[gesture] != nil && view.convert(view.bounds, to: nil).contains(location)
        }
        return claiming.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    var scrollTarget: GestureView? {
        Self.claimant(of: .scroll, at: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil), in: window?.contentView ?? self)
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
        send(.hover, .bool(true))
    }

    override func mouseExited(with _: NSEvent) {
        pointerInside = false
        tooltipPanel?.hide(for: self)
        send(.hover, .bool(false))
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

    var screenFrame: CGRect? {
        window?.convertToScreen(convert(bounds, to: nil))
    }

    func send(_ gesture: Node.Gesture, _ payload: JSON) {
        guard let action = actions[gesture] else { return }
        handler?(ActionEvent(name: action, payload: payload, origin: screenFrame, gesture: gesture))
    }
}

extension NSView {
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        [self].compactMap { $0 as? View } + subviews.flatMap { $0.descendants(type) }
    }

    func node(withAction action: String) -> GestureView? {
        descendants(GestureView.self).first { $0.actions.values.contains(action) }
    }

    func clickable(_ action: String) -> (view: GestureView, gesture: Node.Gesture)? {
        for view in descendants(GestureView.self) {
            if let gesture = view.actions.first(where: { $0.key != .scroll && $0.key != .hover && $0.value == action })?.key {
                return (view, gesture)
            }
        }
        return nil
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
