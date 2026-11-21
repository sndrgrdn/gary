import AppKit
import GaryCore

final class SurfacePanel: NSPanel {
    static let keys: [UInt16: String] = [126: "up", 125: "down", 36: "enter", 76: "enter", 53: "escape", 48: "tab"]

    var focusable = false
    var onKey: ((String) -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { focusable }

    override func keyDown(with event: NSEvent) {
        if let key = Self.keys[event.keyCode], let onKey { onKey(key) } else { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

func makeSurfacePanel(level: Int) -> SurfacePanel {
    let panel = SurfacePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = NSWindow.Level(rawValue: level)
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    return panel
}

extension NSScreen {
    var uuid: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let id = number?.uint32Value, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "unknown" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var notch: ClosedRange<Double>? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return (left.maxX - frame.minX)...(right.minX - frame.minX)
    }

    func display(index: Int, theme: Theme) -> DisplayInfo {
        let notch = notch
        return DisplayInfo(id: uuid, index: index, frame: frame, band: notch != nil ? safeAreaInsets.top : theme.bar.height, notch: notch)
    }
}

extension NSStackView {
    @discardableResult
    func arrange(_ views: [NSView]) -> Int {
        var changes = 0
        let kept = Set(views.map(ObjectIdentifier.init))
        for view in arrangedSubviews where !kept.contains(ObjectIdentifier(view)) {
            removeArrangedSubview(view)
            view.removeFromSuperview()
            changes += 1
        }
        for (index, view) in views.enumerated() where index >= arrangedSubviews.count || arrangedSubviews[index] !== view {
            insertArrangedSubview(view, at: index)
            changes += 1
        }
        return changes
    }
}

final class BarWindow {
    let display: DisplayInfo
    let panel: NSPanel
    private let sections: [BarSection: NSStackView]
    private var constraints: [NSLayoutConstraint] = []

    init(display: DisplayInfo, level: Int) {
        self.display = display
        panel = makeSurfacePanel(level: level)
        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        sections = Dictionary(uniqueKeysWithValues: BarSection.allCases.map { section in
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
            return (section, stack)
        })
    }

    func layout(on screen: NSScreen, theme: Theme) {
        let frame = screen.frame
        let height = display.band
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
        let content = panel.contentView!
        content.layer?.backgroundColor = NSColor(theme.bar.background).cgColor
        let (left, center, right) = (sections[.left]!, sections[.center]!, sections[.right]!)
        for stack in sections.values { stack.spacing = theme.spacing.section }
        let edge = theme.spacing.edge, gap = theme.spacing.section

        NSLayoutConstraint.deactivate(constraints)
        constraints = sections.values.map { $0.centerYAnchor.constraint(equalTo: content.centerYAnchor) } + [
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edge),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: center.trailingAnchor, constant: gap),
        ]
        if display.notch != nil, let beforeNotch = screen.auxiliaryTopLeftArea, let afterNotch = screen.auxiliaryTopRightArea {
            constraints += [
                left.trailingAnchor.constraint(lessThanOrEqualTo: content.leadingAnchor, constant: beforeNotch.maxX - frame.minX - edge),
                center.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: afterNotch.minX - frame.minX + edge),
            ]
        } else {
            constraints += [
                center.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                left.trailingAnchor.constraint(lessThanOrEqualTo: center.leadingAnchor, constant: -gap),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        panel.orderFrontRegardless()
    }

    func setSection(_ section: BarSection, _ views: [NSView]) {
        sections[section]!.arrange(views)
    }

    func close() {
        panel.close()
    }
}

final class SurfaceWindow {
    let panel = makeSurfacePanel(level: 0)
    private let card = NSView()
    private var content: NSView?
    private var edges: [NSLayoutConstraint] = []
    private var size: [NSLayoutConstraint] = []

    init() {
        panel.contentView = card
    }

    func setContent(_ view: NSView) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view)
        edges = [
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            view.topAnchor.constraint(equalTo: card.topAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        for edge in edges.suffix(2) { edge.priority = .init(490) }
        NSLayoutConstraint.activate(edges)
    }

    func place(_ spec: SurfaceSpec, on display: DisplayInfo, level: Int) {
        panel.level = NSWindow.Level(rawValue: level)
        panel.ignoresMouseEvents = spec.clickThrough
        panel.focusable = spec.focusable
        NSLayoutConstraint.deactivate(size)
        let frame = spec.frame(on: display) { width, height in
            fixedSize(width, height, priority: 999).fitting
        }
        size = fixedSize(frame.width, frame.height, priority: 999).constraints
        NSLayoutConstraint.activate(size)
        panel.setFrame(frame, display: false)
    }

    private func fixedSize(_ width: Double?, _ height: Double?, priority: Float) -> (constraints: [NSLayoutConstraint], fitting: CGSize) {
        let constraints = [width.map { card.widthAnchor.constraint(equalToConstant: $0) }, height.map { card.heightAnchor.constraint(equalToConstant: $0) }].compactMap { $0 }
        for constraint in constraints { constraint.priority = .init(priority) }
        NSLayoutConstraint.activate(constraints)
        let fitting = card.fittingSize
        NSLayoutConstraint.deactivate(constraints)
        return (constraints, fitting)
    }

    func show(fade: Double) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 1
        }
    }

    func focus() {
        panel.makeKey()
        var queue = content.map { [$0] } ?? []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view is InputNodeView {
                panel.makeFirstResponder(view)
                return
            }
            queue += view.subviews
        }
    }

    func close(fade: Double) {
        let panel = panel
        panel.ignoresMouseEvents = true
        panel.onKey = nil
        panel.onResignKey = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.close() })
    }

    func contains(_ point: NSPoint) -> Bool { panel.isVisible && NSMouseInRect(point, panel.frame, false) }
}
