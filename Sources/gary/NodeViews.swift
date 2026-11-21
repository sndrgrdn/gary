import AppKit
import Combine
import GaryCore
import SwiftUI

typealias ActionHandler = (String, JSON) -> Void

final class MountedTree: ObservableObject {
    @Published var root: Node
    @Published var theme: Theme
    @Published var fit: Fit?
    @Published var card: Card?

    init(root: Node, theme: Theme) {
        self.root = root
        self.theme = theme
    }
}

final class TreeHostingView: NSHostingView<TreeView> {
    let tree: MountedTree

    init(tree: MountedTree, onAction: @escaping ActionHandler) {
        self.tree = tree
        super.init(rootView: TreeView(tree: tree, onAction: onAction))
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init(rootView: TreeView) { fatalError() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func fit(_ fit: Fit) {
        if tree.fit != fit { tree.fit = fit }
    }

    func paint(_ card: Card?) {
        if tree.card != card { tree.card = card }
    }
}

struct TreeView: View {
    @ObservedObject var tree: MountedTree
    let onAction: ActionHandler

    var body: some View {
        let root = NodeView(node: tree.root)
            .environment(\.nodeTheme, tree.theme)
            .environment(\.nodeAction, onAction)
        if let fit = tree.fit {
            fit { root.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card(tree.card) }
        } else {
            root
        }
    }
}

struct Card: Equatable {
    var look: ResolvedStyle
    var radius: Double
    var border: RGBA?
}

struct Fit: Layout, Equatable {
    var width, height: Double?
    var limit: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = width ?? min(content.sizeThatFits(.unspecified).width, limit.width)
        let height = height ?? min(content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height, limit.height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct ScrollFit: Layout {
    var maxHeight: Double?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroll = subviews.first else { return .zero }
        let content = scroll.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, maxHeight ?? .infinity, proposal.height ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme? = nil
}

private struct ActionKey: EnvironmentKey {
    static let defaultValue: ActionHandler = { _, _ in }
}

extension EnvironmentValues {
    var nodeTheme: Theme? {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var nodeAction: ActionHandler {
        get { self[ActionKey.self] }
        set { self[ActionKey.self] = newValue }
    }
}

private struct Child: Identifiable {
    let id: Node.ChildID
    let node: Node
}

private extension Node {
    var identifiedChildren: [Child] { zip(childIDs, children).map(Child.init) }
}

struct NodeView: View {
    let node: Node
    @Environment(\.nodeTheme) private var theme
    @Environment(\.nodeAction) private var perform

    var body: some View {
        let look = theme!.resolve(node.style, node.props)
        switch node.content {
        case .button(_, let hover):
            ButtonNode(node: node, look: look, hovered: theme!.resolve(node.style, node.props, hover: hover ?? "hover"))
        default:
            content(look).box(look, node, perform)
        }
    }

    @ViewBuilder private func content(_ look: ResolvedStyle) -> some View {
        let gap = look.gap ?? theme!.spacing.item
        switch node.content {
        case .row:
            HStack(alignment: .center, spacing: gap) { Children(node: node) }
        case .column:
            VStack(alignment: .leading, spacing: gap) { Children(node: node) }
        case .scroll:
            ScrollNode(node: node, gap: gap, padding: look.padding ?? Insets(0), maxHeight: look.height)
        case .text(let text):
            Text(verbatim: text).font(Font(nsFont(look.font) as CTFont)).foregroundStyle(Color(look.color))
                .multilineTextAlignment(TextAlignment(look.align ?? .leading)).fixedSize(horizontal: false, vertical: true)
        case .icon(let symbol):
            Image(systemName: symbol).font(.system(size: look.font.size, weight: .init(look.font.weight))).foregroundStyle(Color(look.color))
        case .image(let path):
            if let image = image(path) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
        case .slider(let value):
            SliderNode(value: value, action: node.action, tint: node.props.color == nil ? nil : Color(look.color))
        case .progress(let value):
            let shape = RoundedRectangle(cornerRadius: look.radius ?? 3)
            shape.fill(Color(look.background ?? RGBA(red: look.color.red, green: look.color.green, blue: look.color.blue, alpha: 0.25)))
                .overlay(alignment: .leading) { GeometryReader { area in shape.fill(Color(look.color)).frame(width: area.size.width * value) } }
        case .input(let input):
            InputNode(input: input, font: nsFont(look.font), color: Color(look.color))
        case .spacer:
            Spacer(minLength: 0)
        case .button:
            EmptyView()
        }
    }
}

private struct Children: View {
    let node: Node

    var body: some View {
        ForEach(node.identifiedChildren) { child in NodeView(node: child.node) }
    }
}

private extension View {
    func box(_ look: ResolvedStyle, _ node: Node, _ perform: @escaping ActionHandler) -> some View {
        var width = look.width, height = look.height, padding = look.padding ?? Insets(0), background = look.background
        var clickable = node.action, vertical = VerticalAlignment.center, horizontal = HorizontalAlignment(look.align ?? .leading)
        switch node.content {
        case .column: vertical = .top
        case .scroll: (height, padding, clickable, vertical) = (nil, Insets(0), nil, .top)
        case .image: (width, height) = (width ?? height ?? 16, height ?? width ?? 16)
        case .slider: (width, clickable) = (width ?? 120, nil)
        case .input: (width, clickable) = (width ?? 240, nil)
        case .progress: (width, height, background) = (width ?? 120, height ?? 6, nil)
        case .icon: horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case .row, .button, .text, .spacer: break
        }
        return self
            .padding(EdgeInsets(padding))
            .frame(width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) }, alignment: Alignment(horizontal: horizontal, vertical: vertical))
            .frame(minWidth: look.minWidth.map { CGFloat($0) }, alignment: Alignment(horizontal: horizontal, vertical: vertical))
            .background { if let background { RoundedRectangle(cornerRadius: look.radius ?? 0).fill(Color(background)) } }
            .material(look.material, radius: look.radius ?? 0)
            .opacity(look.opacity ?? 1)
            .offset(y: look.offset ?? 0)
            .transaction(value: node) { transaction in
                switch look.animation {
                case .smooth?: transaction.animation = .smooth
                case .spring?: transaction.animation = .spring
                case GaryCore.Animation.none?: transaction.animation = nil
                case nil: break
                }
            }
            .pressable(clickable) { perform($0, .null) }
            .layoutPriority(node.kind == .spacer ? -1 : 0)
    }

    @ViewBuilder func material(_ material: GaryCore.Material?, radius: Double) -> some View {
        switch material {
        case .vibrant?: background(Vibrancy(radius: radius))
        case .glass?: glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        case GaryCore.Material.none?, nil: self
        }
    }

    @ViewBuilder func card(_ card: Card?) -> some View {
        if let card {
            let shape = RoundedRectangle(cornerRadius: card.radius)
            background { if let background = card.look.background { shape.fill(Color(background)) } }
                .material(card.look.material, radius: card.radius)
                .clipShape(shape)
                .overlay { if let border = card.border { shape.strokeBorder(Color(border), lineWidth: 1) } }
        } else {
            self
        }
    }

    @ViewBuilder func pressable(_ action: String?, _ perform: @escaping (String) -> Void) -> some View {
        if let action {
            contentShape(Rectangle()).onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { pressing in if pressing { perform(action) } })
        } else {
            self
        }
    }
}

private struct ButtonNode: View {
    let node: Node
    let look: ResolvedStyle
    let hovered: ResolvedStyle
    @Environment(\.nodeTheme) private var theme
    @Environment(\.nodeAction) private var perform
    private let hovering = State(initialValue: false)

    var body: some View {
        HStack(alignment: .center, spacing: look.gap ?? theme!.spacing.item) { Children(node: node) }
            .fixedSize()
            .box(hovering.wrappedValue ? hovered : look, node, perform)
            .onHover { hovering.wrappedValue = $0 }
    }
}

private struct ScrollNode: View {
    let node: Node
    let gap: Double
    let padding: Insets
    let maxHeight: Double?

    var body: some View {
        let revealed = node.revealedChild.map { node.childIDs[$0] }
        ScrollFit(maxHeight: maxHeight) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(node.identifiedChildren) { child in NodeView(node: child.node).id(child.id) }
                    }
                    .padding(EdgeInsets(padding))
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: revealed, initial: true) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct Vibrancy: NSViewRepresentable {
    let radius: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = radius > 0 ? Self.roundedMask(radius) : nil
    }

    private static func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private struct SliderNode: View {
    let value: Double
    let action: String?
    let tint: Color?
    @Environment(\.nodeAction) private var perform
    private let shown = State(initialValue: 0.0)

    var body: some View {
        Slider(value: Binding(get: { shown.wrappedValue }, set: { next in
            shown.wrappedValue = next
            if let action { perform(action, .number(next)) }
        }), in: 0...1)
        .tint(tint)
        .onChange(of: value, initial: true) { _, next in shown.wrappedValue = next }
    }
}

private struct InputNode: View {
    let input: Node.Input
    let font: NSFont
    let color: Color
    @Environment(\.nodeAction) private var perform
    private let text = State(initialValue: "")
    private let sent = State(initialValue: [String]())

    private static let keys: [KeyEquivalent: String] = [.upArrow: "up", .downArrow: "down", .tab: "tab", .escape: "escape"]

    var body: some View {
        TextField("", text: Binding(get: { text.wrappedValue }, set: { typed($0) }), prompt: input.placeholder.map { Text($0) })
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(Font(font as CTFont))
            .foregroundStyle(color)
            .onSubmit {
                if let submit = input.submit { perform(submit, .string(text.wrappedValue)) } else { pressKey("enter") }
            }
            .onKeyPress(keys: Set(Self.keys.keys)) { press in
                pressKey(Self.keys[press.key]!)
                return .handled
            }
            .onChange(of: input.value, initial: true) { _, value in
                if let index = sent.wrappedValue.firstIndex(of: value) {
                    sent.wrappedValue.removeFirst(index + 1)
                    return
                }
                sent.wrappedValue = []
                if text.wrappedValue != value { text.wrappedValue = value }
            }
    }

    private func typed(_ next: String) {
        text.wrappedValue = next
        guard let change = input.change else { return }
        sent.wrappedValue.append(next)
        perform(change, .string(next))
    }

    private func pressKey(_ key: String) {
        (NSApp.keyWindow as? SurfacePanel)?.onKey?(key)
    }
}

extension Color {
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension NSColor {
    convenience init(_ rgba: RGBA) {
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

extension EdgeInsets {
    init(_ insets: Insets) {
        self.init(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }
}

extension HorizontalAlignment {
    init(_ align: Align) {
        switch align {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}

extension TextAlignment {
    init(_ align: Align) {
        switch align {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}

extension Font.Weight {
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

private var fonts: [FontToken: NSFont] = [:]

private func nsFont(_ token: FontToken) -> NSFont {
    if let cached = fonts[token] { return cached }
    let weight = NSFont.Weight(token.weight)
    let size = CGFloat(token.size)
    let font: NSFont
    switch token.family {
    case .system:
        font = .systemFont(ofSize: size, weight: weight)
    case .monospaced:
        font = .monospacedSystemFont(ofSize: size, weight: weight)
    case .named(let family):
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        font = NSFont(descriptor: descriptor, size: size).flatMap { $0.familyName == family ? $0 : nil }
            ?? NSFont(name: family, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
    fonts[token] = font
    return font
}

private let images = NSCache<NSString, NSImage>()

private func image(_ path: String) -> NSImage? {
    if let cached = images.object(forKey: path as NSString) { return cached }
    let expanded = (path as NSString).expandingTildeInPath
    let image = expanded.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: expanded) : NSImage(contentsOfFile: expanded)
    if let image { images.setObject(image, forKey: path as NSString) }
    return image
}
