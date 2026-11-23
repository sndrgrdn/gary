import AppKit
import GaryCore
import SwiftUI

final class TooltipPanel {
    static let delay = 0.5

    var theme: Theme
    private let panel = makeSurfacePanel(level: Int(CGWindowLevelForKey(.popUpMenuWindow)))
    private let view: NSHostingView<NodeView>
    private weak var owner: GestureView?
    private var timer: Timer?

    init(theme: Theme) {
        self.theme = theme
        view = NSHostingView(rootView: NodeView(node: Node(.spacer), theme: theme))
        view.sizingOptions = [.intrinsicContentSize]
        panel.contentView = view
        panel.ignoresMouseEvents = true
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    func hover(_ owner: GestureView) {
        guard owner !== self.owner else { return }
        hide()
        self.owner = owner
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.show() } }
    }

    func refresh(_ owner: GestureView) {
        if owner === self.owner, panel.isVisible {
            show()
        }
    }

    func hide(for owner: GestureView) {
        if owner === self.owner {
            hide()
        }
    }

    func hide(inside view: NSView) {
        if let owner, owner.isDescendant(of: view) {
            hide()
        }
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        owner = nil
        panel.orderOut(nil)
    }

    private func show() {
        guard let owner, let text = owner.tooltip, let window = owner.window, let screen = window.screen else {
            hide()
            return
        }
        let origin = screen.display(index: 0, theme: theme).attachment(window.convertToScreen(owner.convert(owner.bounds, to: nil)))
        view.rootView = NodeView(node: Node(.text(text), style: "tooltip"), theme: theme)
        panel.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let bounds = screen.frame.insetBy(dx: theme.spacing.edge, dy: theme.spacing.edge)
        panel.setFrame(SurfaceSpec.attached(view.intrinsicContentSize, to: origin, gap: theme.spacing.item, within: bounds), display: true)
        panel.orderFrontRegardless()
    }
}

private struct TooltipKey: EnvironmentKey {
    static let defaultValue: TooltipPanel? = nil
}

extension EnvironmentValues {
    var tooltipPanel: TooltipPanel? {
        get { self[TooltipKey.self] }
        set { self[TooltipKey.self] = newValue }
    }
}
