import AppKit

private final class TopEdgeView: NSView {
    var onEnter: () -> Void = {}

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
    let edge = TopEdgeView()
    edge.onEnter = onEnter
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
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? []
        return windows.contains { window in
            guard window[kCGWindowOwnerName] as? String == "Window Server",
                  window[kCGWindowLayer] as? Int == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let bounds = (window[kCGWindowBounds] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return false }
            return abs(bounds.minX - frame.minX) < 1 && bounds.maxY > top + 1
        }
    }
}
