import AppKit
import GaryCore

func makeSurfacePanel(level: Int) -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

    var notched: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil }

    func barHeight(_ theme: Theme) -> CGFloat { notched ? safeAreaInsets.top : theme.bar.height }
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

    init(screen: NSScreen, level: Int) {
        display = DisplayInfo(id: screen.uuid, notched: screen.notched)
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
        let height = screen.barHeight(theme)
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
        if display.notched, let beforeNotch = screen.auxiliaryTopLeftArea, let afterNotch = screen.auxiliaryTopRightArea {
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
        panel.orderOut(nil)
    }
}

final class PanelWindow {
    let panel: NSPanel
    private let card = NSView()
    private var content: NSView?

    init(level: Int) {
        panel = makeSurfacePanel(level: level)
        card.wantsLayer = true
        panel.contentView = card
    }

    var isVisible: Bool { panel.isVisible }

    func setContent(_ view: NSView, theme: Theme) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view)
        let padding = theme.panel.padding
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding),
        ])
    }

    func fit(theme: Theme) {
        card.layer?.backgroundColor = NSColor(theme.panel.background).cgColor
        card.layer?.cornerRadius = theme.panel.radius
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = card.fittingSize
        let frame = screen.frame
        let origin = NSPoint(x: frame.maxX - theme.spacing.edge - size.width, y: frame.maxY - screen.barHeight(theme) - 8 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
