import AppKit
import GaryCore

final class ScreenSelection {
    private static var active: ScreenSelection?

    private let windows: [(id: CGWindowID, frame: CGRect)]
    private let finish: (Result<JSON, Error>) -> Void
    private var panels: [NSPanel] = []
    private var anchor: CGPoint?
    private var pointer: CGPoint

    static func run(_ finish: @escaping (Result<JSON, Error>) -> Void) {
        guard active == nil else {
            finish(.failure(HostFailure("another selection is open")))
            return
        }
        let selection = ScreenSelection(finish)
        active = selection
        selection.open()
    }

    private init(_ finish: @escaping (Result<JSON, Error>) -> Void) {
        self.finish = finish
        pointer = globalPoint(NSEvent.mouseLocation)
        windows = WindowInfo.list([.optionOnScreenOnly, .excludeDesktopElements]).compactMap { window in
            guard window.layer == 0, window.owner != getpid(), let frame = window.bounds, frame.width > 1, frame.height > 1 else { return nil }
            return (window.id, frame)
        }
    }

    private func open() {
        panels = NSScreen.screens.map { screen in
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.contentView = SelectionView(selection: self)
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            return panel
        }
        let pointed = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        pointed?.makeKey()
    }

    var highlight: CGRect? {
        if let anchor, dragged {
            return CGRect(
                x: min(anchor.x, pointer.x),
                y: min(anchor.y, pointer.y),
                width: abs(pointer.x - anchor.x),
                height: abs(pointer.y - anchor.y),
            )
        }
        return target(at: pointer)?.frame
    }

    private var dragged: Bool {
        guard let anchor else { return false }
        return abs(pointer.x - anchor.x) >= 4 || abs(pointer.y - anchor.y) >= 4
    }

    private func target(at point: CGPoint) -> (area: ScreenArea, frame: CGRect)? {
        if let window = windows.first(where: { $0.frame.contains(point) }) {
            return (.window(window.id), window.frame)
        }
        guard let screen = NSScreen.screens.first(where: { globalFrame($0).contains(point) }) else { return nil }
        return (.display(screen.uuid), globalFrame(screen))
    }

    func move(to location: NSPoint) {
        pointer = globalPoint(location)
        for panel in panels {
            panel.contentView?.needsDisplay = true
        }
    }

    func press(at location: NSPoint) {
        anchor = globalPoint(location)
        move(to: location)
    }

    func release(at location: NSPoint) {
        move(to: location)
        if dragged, let highlight {
            end(.region(highlight))
        } else {
            end(target(at: pointer)?.area)
        }
    }

    func end(_ area: ScreenArea?) {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        Self.active = nil
        DispatchQueue.main.async { [finish] in finish(.success(area?.json ?? .null)) }
    }
}

private func primaryHeight() -> CGFloat {
    NSScreen.screens.first?.frame.maxY ?? 0
}

private func globalPoint(_ location: NSPoint) -> CGPoint {
    CGPoint(x: location.x, y: primaryHeight() - location.y)
}

private func globalFrame(_ screen: NSScreen) -> CGRect {
    CGRect(x: screen.frame.minX, y: primaryHeight() - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

private final class SelectionView: NSView {
    private let selection: ScreenSelection

    init(selection: ScreenSelection) {
        self.selection = selection
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with _: NSEvent) {
        NSCursor.crosshair.set()
        selection.move(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with _: NSEvent) {
        selection.press(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with _: NSEvent) {
        selection.move(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with _: NSEvent) {
        selection.release(at: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with _: NSEvent) {
        selection.end(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            selection.end(nil)
        }
    }

    override func draw(_: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()
        guard let highlight = selection.highlight, let window else { return }
        let origin = window.frame.origin
        let local = CGRect(
            x: highlight.minX - origin.x,
            y: primaryHeight() - highlight.maxY - origin.y,
            width: highlight.width,
            height: highlight.height,
        )
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        local.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}
