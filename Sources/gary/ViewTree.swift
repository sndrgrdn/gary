import AppKit
import GaryCore

protocol NodeView: NSView {
    var nodeAction: String? { get set }
    var onAction: ((String) -> Void)? { get set }
}

extension NodeView {
    func click(_ event: NSEvent) {
        if let nodeAction { onAction?(nodeAction) } else { nextResponder?.mouseDown(with: event) }
    }
}

final class TextNodeView: NSTextField, NodeView {
    var nodeAction: String?
    var onAction: ((String) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }
}

final class IconNodeView: NSImageView, NodeView {
    var nodeAction: String?
    var onAction: ((String) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }
}

final class StackNodeView: NSStackView, NodeView {
    var nodeAction: String?
    var onAction: ((String) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }
}

final class SpacerNodeView: NSView, NodeView {
    var nodeAction: String?
    var onAction: ((String) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(event) }
}

final class ViewRenderer {
    let theme: Theme
    private var resolved: [String: (font: NSFont, color: NSColor)] = [:]

    init(theme: Theme) { self.theme = theme }

    func build(_ node: Node, onAction: @escaping (String) -> Void) -> NSView {
        let view: NodeView
        switch node.content {
        case .row(let children), .column(let children):
            let stack = StackNodeView(views: children.map { build($0, onAction: onAction) })
            stack.orientation = node.kind == .row ? .horizontal : .vertical
            stack.alignment = node.kind == .row ? .centerY : .leading
            stack.setHuggingPriority(.required, for: node.kind == .row ? .horizontal : .vertical)
            view = stack
        case .text(let text):
            let label = TextNodeView(labelWithString: text)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            view = label
        case .icon:
            let icon = IconNodeView()
            icon.imageScaling = .scaleNone
            icon.setContentHuggingPriority(.required, for: .horizontal)
            view = icon
        case .spacer:
            let spacer = SpacerNodeView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            view = spacer
        }
        view.onAction = onAction
        style(view, value: node.value, style: node.style, action: node.action)
        return view
    }

    func apply(_ patch: Patch, to view: NSView, onAction: @escaping (String) -> Void) -> (view: NSView, mutations: Int) {
        switch patch {
        case .replace(let node):
            return (build(node, onAction: onAction), 1)
        case .update(let attributes, let children):
            var mutations = 0
            if let attributes {
                style(view, value: attributes.value, style: attributes.style, action: attributes.action)
                mutations += 1
            }
            if let children, let stack = view as? NSStackView {
                let old = stack.arrangedSubviews
                let next = children.map { child -> NSView in
                    switch child {
                    case .reuse(let index, let patch):
                        if let patch { mutations += apply(patch, to: old[index], onAction: onAction).mutations }
                        return old[index]
                    case .create(let node):
                        mutations += 1
                        return build(node, onAction: onAction)
                    }
                }
                mutations += stack.arrange(next)
            }
            return (view, mutations)
        }
    }

    func restyle(_ view: NSView, _ node: Node) {
        style(view, value: node.value, style: node.style, action: node.action)
        guard let stack = view as? NSStackView else { return }
        for (child, childNode) in zip(stack.arrangedSubviews, node.children) { restyle(child, childNode) }
    }

    private func style(_ view: NSView, value: String?, style name: String?, action: String?) {
        (view as? NodeView)?.nodeAction = action
        let style = resolve(name)
        switch view {
        case let label as TextNodeView:
            label.stringValue = value ?? ""
            label.font = style.font
            label.textColor = style.color
        case let icon as IconNodeView:
            icon.image = value.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: $0) }
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.font.pointSize, weight: .init(theme.style(name).font.weight))
            icon.contentTintColor = style.color
        case let stack as NSStackView:
            stack.spacing = theme.spacing.item
        default:
            break
        }
    }

    private func resolve(_ name: String?) -> (font: NSFont, color: NSColor) {
        let key = name ?? "default"
        if let cached = resolved[key] { return cached }
        let style = theme.style(name)
        let value = (makeFont(style.font), NSColor(style.color))
        resolved[key] = value
        return value
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
