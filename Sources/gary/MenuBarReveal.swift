import AppKit

private final class TopEdgeView: NSView {
    private let onEnter: () -> Void

    init(onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        super.init(frame: .zero)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with _: NSEvent) {
        onEnter()
    }
}

func watchTopEdge(of view: NSView, _ onEnter: @escaping () -> Void) {
    let edge = TopEdgeView(onEnter: onEnter)
    edge.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(edge)
    NSLayoutConstraint.activate([
        edge.topAnchor.constraint(equalTo: view.topAnchor),
        edge.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        edge.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        edge.heightAnchor.constraint(equalToConstant: 2),
    ])
}

enum NativeMenuBar {
    static func revealed(on frame: CGRect) -> Bool {
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
        return OnScreenWindow.list(.optionOnScreenOnly).contains { window in
            guard window.ownerName == "Window Server", window.layer == Int(CGWindowLevelForKey(.mainMenuWindow)), let bounds = window.bounds
            else { return false }
            return abs(bounds.minX - frame.minX) < 1 && bounds.maxY > top + 1
        }
    }
}
