import AppKit
import GaryCore

typealias ActionHandler = (String, JSON) -> Void

protocol NodeView: NSView {
    var nodeAction: String? { get set }
    var onAction: ActionHandler? { get set }
    var sizing: [NSLayoutConstraint] { get set }
}

extension NodeView {
    func click(_ event: NSEvent) {
        if let nodeAction { onAction?(nodeAction, .null) } else { nextResponder?.mouseDown(with: event) }
    }
}

final class TextNodeView: NSTextField, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    private var wrapWidth: CGFloat = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }

    override var intrinsicContentSize: NSSize {
        guard let cell else { return super.intrinsicContentSize }
        let unbounded = CGFloat.greatestFiniteMagnitude
        let natural = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: unbounded, height: unbounded))
        let lines = wrapWidth > 0 && wrapWidth < natural.width ? cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: wrapWidth, height: unbounded)) : natural
        return NSSize(width: ceil(natural.width), height: ceil(lines.height))
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - wrapWidth) >= 0.5 else { return }
        wrapWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

final class IconNodeView: NSImageView, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }
}

class StackNodeView: NSStackView, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    private var crossInsets: [NSLayoutConstraint] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }

    func pinCrossAxis(_ node: Node) {
        NSLayoutConstraint.deactivate(crossInsets)
        let cross: Node.Axis = orientation == .vertical ? .horizontal : .vertical
        crossInsets = zip(arrangedSubviews, node.children).flatMap { view, child -> [NSLayoutConstraint] in
            let fills = child.grows(along: cross)
            return orientation == .vertical
                ? [fills ? trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: edgeInsets.right)
                         : trailingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor, constant: edgeInsets.right)]
                : [fills ? bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: edgeInsets.bottom)
                         : bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor, constant: edgeInsets.bottom),
                   fills ? view.topAnchor.constraint(equalTo: topAnchor, constant: edgeInsets.top)
                         : view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: edgeInsets.top)]
        }
        for constraint in crossInsets { constraint.priority = .defaultHigh }
        NSLayoutConstraint.activate(crossInsets)
    }
}

final class FlippedStackView: StackNodeView {
    private var pendingReveal = false
    var reveal: Int? {
        didSet {
            guard reveal != oldValue, reveal != nil else { return }
            pendingReveal = true
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard pendingReveal, let reveal, reveal < arrangedSubviews.count else { return }
        pendingReveal = false
        scrollToVisible(arrangedSubviews[reveal].frame)
    }
}

final class ButtonNodeView: StackNodeView {
    var looks: (normal: ResolvedStyle, hovered: ResolvedStyle)? { didSet { paint() } }
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func pinCrossAxis(_ node: Node) {
        super.pinCrossAxis(node)
        for case let label as TextNodeView in arrangedSubviews { label.setContentCompressionResistancePriority(.required, for: .horizontal) }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
    override func mouseExited(with event: NSEvent) { hovered = false; paint() }

    private func paint() {
        guard let looks else { return }
        paintBox(self, hovered ? looks.hovered : looks.normal)
    }
}

final class ScrollNodeView: NSScrollView, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    let stack = FlippedStackView()
}

final class SpacerNodeView: NSView, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }
}

final class SliderNodeView: NSSlider, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func changed(_ sender: Any?) {
        if let nodeAction { onAction?(nodeAction, .number(doubleValue)) }
    }
}

final class ProgressNodeView: NSView, NodeView {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    let fill = CALayer()
    var fraction = 0.0 { didSet { needsLayout = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 6) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        fill.cornerRadius = layer?.cornerRadius ?? 0
        CATransaction.commit()
    }
}

final class InputNodeView: NSTextField, NodeView, NSTextFieldDelegate {
    var nodeAction: String?
    var onAction: ActionHandler?
    var sizing: [NSLayoutConstraint] = []
    var input = Node.Input(value: "")
    private var sent: [String] = []

    func show(_ next: Node.Input) {
        input = next
        placeholderString = next.placeholder
        if let index = sent.firstIndex(of: next.value) {
            sent.removeFirst(index + 1)
            return
        }
        sent = []
        if stringValue != next.value { stringValue = next.value }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let change = input.change else { return }
        sent.append(stringValue)
        onAction?(change, .string(stringValue))
    }

    private static let keys: [Selector: String] = [
        #selector(NSResponder.moveUp(_:)): "up", #selector(NSResponder.moveDown(_:)): "down", #selector(NSResponder.insertTab(_:)): "tab",
        #selector(NSResponder.cancelOperation(_:)): "escape", #selector(NSResponder.insertNewline(_:)): "enter",
    ]

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let submit = input.submit {
            onAction?(submit, .string(stringValue))
            return true
        }
        guard let key = Self.keys[selector], let onKey = (window as? SurfacePanel)?.onKey else { return false }
        onKey(key)
        return true
    }
}

func paintBox(_ view: NSView, _ look: ResolvedStyle) {
    if look.background != nil || look.radius != nil || view.layer != nil {
        view.wantsLayer = true
        view.layer?.backgroundColor = look.background.map { NSColor($0).cgColor }
        view.layer?.cornerRadius = look.radius ?? 0
    }
    view.alphaValue = look.opacity ?? 1
}

final class ViewRenderer {
    let theme: Theme
    private var fonts: [FontToken: NSFont] = [:]
    private let images = NSCache<NSString, NSImage>()

    init(theme: Theme) { self.theme = theme }

    func build(_ node: Node, onAction: @escaping ActionHandler) -> NSView {
        let view: NodeView
        switch node.content {
        case .row(let children), .column(let children), .button(let children, _):
            let stack = node.kind == .button ? ButtonNodeView() : StackNodeView()
            stack.setViews(children.map { build($0, onAction: onAction) }, in: .leading)
            stack.orientation = node.kind == .column ? .vertical : .horizontal
            stack.alignment = node.kind == .column ? .leading : .centerY
            stack.setHuggingPriority(.required, for: node.kind == .column ? .vertical : .horizontal)
            view = stack
        case .scroll(let children, _):
            let scroll = ScrollNodeView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.stack.orientation = .vertical
            scroll.stack.alignment = .leading
            scroll.stack.setViews(children.map { build($0, onAction: onAction) }, in: .leading)
            scroll.stack.reveal = node.revealedChild
            scroll.stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = scroll.stack
            NSLayoutConstraint.activate([
                scroll.stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                scroll.stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            ])
            let fitWidth = scroll.widthAnchor.constraint(equalTo: scroll.stack.widthAnchor)
            fitWidth.priority = .defaultHigh
            fitWidth.isActive = true
            view = scroll
        case .text:
            let label = TextNodeView(wrappingLabelWithString: "")
            label.isSelectable = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.init(749), for: .horizontal)
            view = label
        case .icon:
            let icon = IconNodeView()
            icon.imageScaling = .scaleNone
            icon.setContentHuggingPriority(.required, for: .horizontal)
            view = icon
        case .image:
            let image = IconNodeView()
            image.imageScaling = .scaleProportionallyUpOrDown
            view = image
        case .slider:
            let slider = SliderNodeView()
            slider.minValue = 0
            slider.maxValue = 1
            slider.isContinuous = true
            slider.target = slider
            slider.action = #selector(SliderNodeView.changed(_:))
            view = slider
        case .progress:
            let progress = ProgressNodeView()
            progress.wantsLayer = true
            progress.layer?.addSublayer(progress.fill)
            view = progress
        case .input:
            let input = InputNodeView()
            input.delegate = input
            input.isBordered = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view = input
        case .spacer:
            let spacer = SpacerNodeView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            view = spacer
        }
        view.onAction = onAction
        style(view, node)
        return view
    }

    func apply(_ patch: Patch, to view: NSView, node: Node, onAction: @escaping ActionHandler) -> (view: NSView, mutations: Int) {
        switch patch {
        case .replace:
            return (build(node, onAction: onAction), 1)
        case .update(let own, let children):
            var mutations = 0
            if let own {
                style(view, own)
                mutations += 1
            }
            if let children, let stack = childStack(view) {
                let old = stack.arrangedSubviews
                let next = zip(children, node.children).map { child, childNode -> NSView in
                    switch child {
                    case .reuse(let index, let patch):
                        if let patch { mutations += apply(patch, to: old[index], node: childNode, onAction: onAction).mutations }
                        return old[index]
                    case .create:
                        mutations += 1
                        return build(childNode, onAction: onAction)
                    }
                }
                mutations += stack.arrange(next)
                (stack as? StackNodeView)?.pinCrossAxis(node)
            }
            (view as? ScrollNodeView)?.stack.reveal = node.revealedChild
            return (view, mutations)
        }
    }

    func restyle(_ view: NSView, _ node: Node) {
        style(view, node)
        guard let stack = childStack(view) else { return }
        for (child, childNode) in zip(stack.arrangedSubviews, node.children) { restyle(child, childNode) }
    }

    private func childStack(_ view: NSView) -> NSStackView? {
        (view as? ScrollNodeView)?.stack ?? view as? NSStackView
    }

    private func style(_ view: NSView, _ node: Node) {
        guard let view = view as? NodeView else { return }
        view.nodeAction = node.action
        let look = theme.resolve(node.style, node.props)
        paintBox(view, look)
        var width = look.width, height = look.height
        switch (view, node.content) {
        case (let label as TextNodeView, .text(let text)):
            label.stringValue = text
            label.font = font(look.font)
            label.textColor = NSColor(look.color)
        case (let icon as IconNodeView, .icon(let symbol)):
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: look.font.size, weight: .init(look.font.weight))
            icon.contentTintColor = NSColor(look.color)
        case (let image as IconNodeView, .image(let path)):
            image.image = self.image(path)
            width = width ?? height ?? 16
            height = height ?? width
        case (let button as ButtonNodeView, .button(_, let hover)):
            button.spacing = look.gap ?? theme.spacing.item
            button.edgeInsets = insets(look.padding)
            button.setHuggingPriority(width == nil ? .required : .defaultLow, for: .horizontal)
            button.looks = (look, theme.resolve(node.style, node.props, hover: hover ?? "hover"))
            button.pinCrossAxis(node)
        case (let scroll as ScrollNodeView, _):
            scroll.stack.spacing = look.gap ?? theme.spacing.item
            scroll.stack.edgeInsets = insets(look.padding)
            scroll.stack.pinCrossAxis(node)
            let fit = scroll.heightAnchor.constraint(equalTo: scroll.stack.heightAnchor)
            fit.priority = .defaultHigh
            scroll.sizing = replace(scroll.sizing, with: [
                fit,
                height.map { scroll.heightAnchor.constraint(lessThanOrEqualToConstant: $0) },
                width.map { scroll.widthAnchor.constraint(equalToConstant: $0) },
            ].compactMap { $0 })
            return
        case (let stack as StackNodeView, _):
            stack.spacing = look.gap ?? theme.spacing.item
            stack.edgeInsets = insets(look.padding)
            let horizontal = stack.orientation == .horizontal
            let hugs = (horizontal ? width : height) == nil && !node.grows(along: horizontal ? .horizontal : .vertical)
            stack.setHuggingPriority(hugs ? .required : .defaultLow, for: horizontal ? .horizontal : .vertical)
            stack.pinCrossAxis(node)
        case (let slider as SliderNodeView, .slider(let value)):
            slider.doubleValue = value
            slider.trackFillColor = node.props.color == nil ? nil : NSColor(look.color)
            width = width ?? 120
        case (let progress as ProgressNodeView, .progress(let value)):
            progress.fraction = value
            progress.fill.backgroundColor = NSColor(look.color).cgColor
            if look.background == nil { progress.layer?.backgroundColor = NSColor(look.color).withAlphaComponent(0.25).cgColor }
            progress.layer?.cornerRadius = look.radius ?? 3
        case (let input as InputNodeView, .input(let value)):
            input.show(value)
            input.font = font(look.font)
            input.textColor = NSColor(look.color)
            width = width ?? 240
        default:
            break
        }
        view.sizing = replace(view.sizing, with: [
            width.map { view.widthAnchor.constraint(equalToConstant: $0) },
            height.map { view.heightAnchor.constraint(equalToConstant: $0) },
        ].compactMap { $0 })
    }

    private func replace(_ old: [NSLayoutConstraint], with new: [NSLayoutConstraint]) -> [NSLayoutConstraint] {
        guard old.map(\.constant) != new.map(\.constant) || old.count != new.count else { return old }
        NSLayoutConstraint.deactivate(old)
        for constraint in new where constraint.priority == .required { constraint.priority = .init(999) }
        NSLayoutConstraint.activate(new)
        return new
    }

    private func insets(_ padding: Double?) -> NSEdgeInsets {
        let value = padding ?? 0
        return NSEdgeInsets(top: value, left: value, bottom: value, right: value)
    }

    private func font(_ token: FontToken) -> NSFont {
        if let cached = fonts[token] { return cached }
        let font = makeFont(token)
        fonts[token] = font
        return font
    }

    private func image(_ path: String) -> NSImage? {
        if let cached = images.object(forKey: path as NSString) { return cached }
        let expanded = (path as NSString).expandingTildeInPath
        let image = expanded.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: expanded) : NSImage(contentsOfFile: expanded)
        if let image { images.setObject(image, forKey: path as NSString) }
        return image
    }
}

extension NSColor {
    convenience init(_ rgba: RGBA) {
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

extension NSFont.Weight {
    init(_ weight: FontToken.Weight) {
        switch weight {
        case .ultralight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        }
    }
}

func makeFont(_ token: FontToken) -> NSFont {
    let weight = NSFont.Weight(token.weight)
    let size = CGFloat(token.size)
    switch token.family {
    case .system:
        return .systemFont(ofSize: size, weight: weight)
    case .monospaced:
        return .monospacedSystemFont(ofSize: size, weight: weight)
    case .named(let family):
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: size).flatMap { $0.familyName == family ? $0 : nil }
            ?? NSFont(name: family, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
}
