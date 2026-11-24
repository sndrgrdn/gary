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
        if let onKey, let key = event.keyName {
            onKey(key)
        } else {
            super.keyDown(with: event)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            FrameLog.shared.arm(for: 0)
        }
        if event.type == .scrollWheel, let onScroll, !(contentView?.hitTest(event.locationInWindow) is GestureView) {
            onScroll(event.scrollEvent)
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

extension NSEvent {
    var keyName: String? {
        KeyStroke(
            keyCode: keyCode,
            characters: characters,
            ignoringModifiers: charactersIgnoringModifiers,
            modifiers: KeyModifiers(modifierFlags),
        ).name
    }

    static func keyDown(named name: String, windowNumber: Int) -> NSEvent? {
        KeyStroke(named: name).flatMap { stroke in
            keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(stroke.modifiers.held.map(\.flag)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: stroke.characters ?? "",
                charactersIgnoringModifiers: stroke.ignoringModifiers ?? "",
                isARepeat: false,
                keyCode: stroke.keyCode,
            )
        }
    }

    var scrollEvent: JSON {
        let phase = if !momentumPhase.isEmpty {
            "momentum"
        } else if phase.contains(.began) || phase.contains(.mayBegin) {
            "began"
        } else if phase.contains(.changed) {
            "changed"
        } else if phase.contains(.ended) || phase.contains(.cancelled) {
            "ended"
        } else {
            "none"
        }
        return .scroll(x: scrollingDeltaX, y: scrollingDeltaY, precise: hasPreciseScrollingDeltas, phase: phase)
    }
}

extension JSON {
    static func scroll(x: Double, y: Double, precise: Bool, phase: String) -> JSON {
        .object(["x": .number(x), "y": .number(y), "precise": .bool(precise), "phase": .string(phase)])
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
        return DisplayInfo(
            id: uuid, index: index, frame: frame, band: notch != nil ? safeAreaInsets.top : theme.bar.height,
            notch: notch, refreshRate: maximumFramesPerSecond,
        )
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
    private let notchLeft = NSStackView()
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
        [left, center, right, notchLeft]
    }

    private func stack(_ section: BarSection) -> NSStackView {
        switch section {
        case .left: left
        case .center: center
        case .right: right
        case .notchLeft: notchLeft
        }
    }

    func layout(theme: Theme) {
        let frame = display.frame
        let height = display.band
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
        content.layer?.backgroundColor = NSColor(theme.bar.background).cgColor
        for stack in sections {
            stack.spacing = theme.bar.gap
        }
        let edge = theme.bar.edge
        let gap = theme.spacing.section

        NSLayoutConstraint.deactivate(constraints)
        constraints = sections.map { $0.centerYAnchor.constraint(equalTo: content.centerYAnchor) } + [
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edge),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
        ]
        let hug = theme.bar.gap
        if let notch = display.notch {
            constraints += [
                notchLeft.trailingAnchor.constraint(equalTo: content.leadingAnchor, constant: notch.lowerBound - hug),
                center.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: notch.upperBound + hug),
                left.trailingAnchor.constraint(lessThanOrEqualTo: notchLeft.leadingAnchor, constant: -edge),
                right.leadingAnchor.constraint(greaterThanOrEqualTo: center.trailingAnchor, constant: gap),
            ]
        } else {
            constraints += [
                center.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                notchLeft.trailingAnchor.constraint(equalTo: center.leadingAnchor, constant: -hug),
                left.trailingAnchor.constraint(lessThanOrEqualTo: notchLeft.leadingAnchor, constant: -gap),
                right.leadingAnchor.constraint(greaterThanOrEqualTo: center.trailingAnchor, constant: gap),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        panel.orderFrontRegardless()
    }

    func setSection(_ section: BarSection, _ views: [NSView]) {
        let resistance: NSLayoutConstraint.Priority = switch section {
        case .left, .right: .windowSizeStayPut - 1
        case .center: .windowSizeStayPut - 2
        case .notchLeft: .defaultLow
        }
        for view in views {
            view.setContentCompressionResistancePriority(resistance, for: .horizontal)
        }
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
    private var shows = 0

    init() {
        card.wantsLayer = true
        panel.contentView = card
        panel.initialFirstResponder = card
    }

    func setContent(_ view: TreeHostingView) {
        guard view !== content || view.superview == nil else { return }
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

    func place(_ spec: SurfaceSpec, on display: DisplayInfo, origin: CGRect?, level: Int, theme: Theme) {
        paint(spec, theme)
        panel.level = NSWindow.Level(rawValue: level)
        panel.ignoresMouseEvents = spec.clickThrough
        panel.focusable = spec.focusable
        let frame = spec.frame(on: display, attachedTo: origin, edge: theme.spacing.edge) { width, height, limit in
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
            spec.background == .solid
                ? Card(look: look, radius: radius, border: look.borderColor ?? theme.color("border"), borderWidth: look.border?.width ?? 1)
                : nil,
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
        FrameLog.shared.arm(for: fade)
        shows += 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard fade > 0 else { return }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = fade
        appear.timingFunction = CAMediaTimingFunction(name: .default)
        card.layer?.add(appear, forKey: "appear")
    }

    func focus() {
        panel.makeKey()
        guard !focusField() else { return }
        let shown = shows
        DispatchQueue.main.async { [self] in
            if shows == shown, panel.isKeyWindow {
                focusField()
            }
        }
    }

    @discardableResult
    private func focusField() -> Bool {
        var queue: [NSView] = content.map { [$0] } ?? []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view is NSTextField {
                panel.makeFirstResponder(view)
                return true
            }
            queue += view.subviews
        }
        return false
    }

    func hide(fade: Double) {
        FrameLog.shared.arm(for: fade)
        let panel = panel
        let shown = shows
        panel.ignoresMouseEvents = true
        panel.onKey = nil
        panel.onScroll = nil
        panel.onResignKey = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if self.shows == shown {
                    self.content?.removeFromSuperview()
                }
            }
        }
    }

    var isShown: Bool {
        panel.isVisible && content?.superview != nil
    }

    func contains(_ point: NSPoint) -> Bool {
        isShown && NSMouseInRect(point, panel.frame, false)
    }
}
