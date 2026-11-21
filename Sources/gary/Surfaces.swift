import AppKit
import GaryCore

final class SurfacePanel: NSPanel {
    var focusable = false
    var onKey: ((String) -> Void)?
    var onScroll: ((JSON) -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool {
        focusable
    }

    override func keyDown(with event: NSEvent) {
        let pairs: [(NSEvent.ModifierFlags, KeyName.Modifiers)] = [(.control, .control), (.option, .option), (.shift, .shift), (.command, .command)]
        var modifiers = KeyName.Modifiers()
        for (flag, modifier) in pairs where event.modifierFlags.contains(flag) {
            modifiers.insert(modifier)
        }
        if let onKey, let key = KeyName.name(
            keyCode: event.keyCode,
            characters: event.characters,
            ignoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers,
        ) {
            onKey(key)
        } else {
            super.keyDown(with: event)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            let phase = if !event.momentumPhase.isEmpty {
                "momentum"
            } else if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                "began"
            } else if event.phase.contains(.changed) {
                "changed"
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                "ended"
            } else {
                "none"
            }
            onScroll(.object([
                "x": .number(event.scrollingDeltaX), "y": .number(event.scrollingDeltaY),
                "precise": .bool(event.hasPreciseScrollingDeltas), "phase": .string(phase),
            ]))
        }
        super.sendEvent(event)
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
        guard let id = number?.uint32Value else { return "unknown" }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
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
    var display: DisplayInfo
    let panel: NSPanel
    let content = NSView()
    private let left = NSStackView()
    private let center = NSStackView()
    private let right = NSStackView()
    private var constraints: [NSLayoutConstraint] = []

    init(display: DisplayInfo, level: Int) {
        self.display = display
        panel = makeSurfacePanel(level: level)
        content.wantsLayer = true
        panel.contentView = content
        for stack in sections {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
        }
    }

    private var sections: [NSStackView] {
        [left, center, right]
    }

    private func stack(_ section: BarSection) -> NSStackView {
        switch section {
        case .left: left
        case .center: center
        case .right: right
        }
    }

    func layout(theme: Theme) {
        let frame = display.frame
        let height = display.band
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
        content.layer?.backgroundColor = NSColor(theme.bar.background).cgColor
        for stack in sections {
            stack.spacing = theme.spacing.section
        }
        let edge = theme.spacing.edge
        let gap = theme.spacing.section

        NSLayoutConstraint.deactivate(constraints)
        constraints = sections.map { $0.centerYAnchor.constraint(equalTo: content.centerYAnchor) } + [
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edge),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: center.trailingAnchor, constant: gap),
        ]
        if let notch = display.notch {
            constraints += [
                left.trailingAnchor.constraint(lessThanOrEqualTo: content.leadingAnchor, constant: notch.lowerBound - edge),
                center.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: notch.upperBound + edge),
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
        stack(section).arrange(views)
    }

    func close() {
        panel.close()
    }
}

final class SurfaceWindow {
    let panel = makeSurfacePanel(level: 0)
    let card = NSView()
    private var content: TreeHostingView?

    init() {
        card.wantsLayer = true
        panel.contentView = card
    }

    func setContent(_ view: TreeHostingView) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = card.bounds
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.init(1), for: orientation)
            view.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        card.addSubview(view)
    }

    func place(_ spec: SurfaceSpec, on display: DisplayInfo, level: Int, theme: Theme) {
        paint(spec, theme)
        panel.level = NSWindow.Level(rawValue: level)
        panel.ignoresMouseEvents = spec.clickThrough
        panel.focusable = spec.focusable
        let frame = spec.frame(on: display) { width, height, limit in
            measure(Fit(width: width, height: height, limit: limit))
        }
        content?.fit(Fit(width: frame.width, height: frame.height, limit: frame.size))
        panel.setFrame(frame, display: false)
        if panel.hasShadow {
            panel.invalidateShadow()
        }
    }

    private func paint(_ spec: SurfaceSpec, _ theme: Theme) {
        let look = theme.style("surface")
        let radius = spec.anchors == SurfaceSpec.all ? 0 : look.radius ?? 0
        content?.paint(
            spec.background == .solid ? Card(look: look, radius: radius, border: theme.color("border")) : nil,
            backdrop: spec.background == .backdrop,
        )
        panel.hasShadow = spec.background == .solid
    }

    private func measure(_ fit: Fit) -> CGSize {
        guard let content else { return .zero }
        content.fit(fit)
        content.layoutSubtreeIfNeeded()
        return content.intrinsicContentSize
    }

    func show(fade: Double) {
        card.alphaValue = 0
        panel.orderFrontRegardless()
        let card = card
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            card.animator().alphaValue = 1
        }
    }

    func focus() {
        panel.makeKey()
        var queue: [NSView] = content.map { [$0] } ?? []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view is NSTextField {
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
        panel.onScroll = nil
        panel.onResignKey = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.close()
        }
    }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && NSMouseInRect(point, panel.frame, false)
    }
}
