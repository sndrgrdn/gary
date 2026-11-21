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
    @Published var backdrop = false

    init(root: Node, theme: Theme) {
        self.root = root
        self.theme = theme
    }
}

final class TreeHostingView: NSHostingView<TreeView> {
    let tree: MountedTree

    init(tree: MountedTree, onAction: @escaping ActionHandler, onDismiss: @escaping () -> Void = {}) {
        self.tree = tree
        super.init(rootView: TreeView(tree: tree, onAction: onAction, onDismiss: onDismiss))
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init(rootView _: TreeView) {
        fatalError()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func fit(_ fit: Fit) {
        if tree.fit != fit {
            tree.fit = fit
        }
    }

    func paint(_ card: Card?, backdrop: Bool) {
        if tree.card != card {
            tree.card = card
        }
        if tree.backdrop != backdrop {
            tree.backdrop = backdrop
        }
    }
}

struct TreeView: View {
    @ObservedObject var tree: MountedTree
    let onAction: ActionHandler
    let onDismiss: () -> Void

    var body: some View {
        let root = NodeView(node: tree.root)
            .environment(\.nodeTheme, tree.theme)
            .environment(\.nodeAction, onAction)
        if let fit = tree.fit, tree.backdrop {
            fit {
                ZStack {
                    Color.black.opacity(0.005).onTapGesture(perform: onDismiss)
                    root
                }
            }
        } else if let fit = tree.fit {
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
    var width: Double?
    var height: Double?
    var limit: CGSize

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = width ?? min(content.sizeThatFits(.unspecified).width, limit.width)
        let height = height ?? min(content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height, limit.height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct ScrollFit: Layout {
    var maxHeight: Double?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let scroll = subviews.first else { return .zero }
        let content = scroll.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, maxHeight ?? .infinity, proposal.height ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
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
    var identifiedChildren: [Child] {
        zip(childIDs, children).map(Child.init)
    }
}

struct NodeView: View {
    let node: Node
    @Environment(\.nodeTheme) private var theme
    @Environment(\.nodeAction) private var perform
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hovering = State(initialValue: false)
    private let pressing = State(initialValue: false)

    var body: some View {
        var props = node.props
        if hovering.wrappedValue, let hovered = node.hovered {
            props = hovered.over(props)
        }
        if pressing.wrappedValue, let pressed = node.pressed {
            props = pressed.over(props)
        }
        var hover: String?
        if hovering.wrappedValue, case let .button(_, style) = node.content {
            hover = style ?? "hover"
        }
        let look = theme!.resolve(node.style, props, hover: hover)
        let tracksHover = node.hovered != nil || node.kind == .button
        let fade: SwiftUI.Animation? = reduceMotion || node.kind == .button ? nil : .easeOut(duration: 0.15)
        return content(look).box(
            look,
            node,
            perform,
            reduceMotion: reduceMotion,
            hovering: tracksHover ? animated(hovering, fade) : nil,
            pressing: node.pressed != nil ? animated(pressing, fade) : nil,
        )
    }

    private func animated(_ state: State<Bool>, _ animation: SwiftUI.Animation?) -> Binding<Bool> {
        Binding(get: { state.wrappedValue }, set: { next in withAnimation(animation) { state.wrappedValue = next } })
    }

    @ViewBuilder private func content(_ look: ResolvedStyle) -> some View {
        let gap = look.gap ?? theme!.spacing.item
        switch node.content {
        case .row:
            HStack(alignment: .center, spacing: gap) { Children(node: node) }
        case .column:
            VStack(alignment: .leading, spacing: gap) { Children(node: node) }
        case .stack:
            ZStack(alignment: .topLeading) { Children(node: node) }
        case .scroll:
            ScrollNode(node: node, gap: gap, padding: look.padding ?? Insets(0), maxHeight: look.height)
        case let .text(text):
            Text(verbatim: text).font(Font(nsFont(look.font) as CTFont)).foregroundStyle(Color(look.color))
                .multilineTextAlignment(TextAlignment(look.align ?? .leading)).fixedSize(horizontal: look.width != nil, vertical: true)
        case let .icon(symbol):
            Image(systemName: symbol).font(.system(size: look.font.size, weight: .init(look.font.weight))).foregroundStyle(Color(look.color))
        case let .image(path):
            ImageNode(
                path: path,
                fit: look.fit ?? .fit,
                size: CGSize(width: look.width ?? look.height ?? 16, height: look.height ?? look.width ?? 16),
                arrival: reduceMotion ? nil : look.animation.flatMap { SwiftUI.Animation($0, duration: look.duration) },
                transition: AnyTransition(look.transition ?? .opacity),
            )
        case let .slider(value):
            SliderNode(value: value, action: node.action, tint: node.props.color == nil ? nil : Color(look.color))
        case let .progress(value):
            let shape = RoundedRectangle(cornerRadius: look.radius ?? 3)
            shape.fill(Color(look.background ?? RGBA(red: look.color.red, green: look.color.green, blue: look.color.blue, alpha: 0.25)))
                .overlay(alignment: .leading) { GeometryReader { area in shape.fill(Color(look.color)).frame(width: area.size.width * value) } }
        case let .input(input):
            InputNode(input: input, font: nsFont(look.font), color: Color(look.color))
        case .spacer:
            Spacer(minLength: 0)
        case .button:
            HStack(alignment: .center, spacing: gap) { Children(node: node) }.fixedSize()
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
    func box(
        _ look: ResolvedStyle,
        _ node: Node,
        _ perform: @escaping ActionHandler,
        reduceMotion: Bool,
        hovering: Binding<Bool>?,
        pressing: Binding<Bool>?,
    ) -> some View {
        var width = look.width
        var height = look.height
        var padding = look.padding ?? Insets(0)
        var background = look.background
        var clickable = node.action
        var vertical = VerticalAlignment.center
        var horizontal = HorizontalAlignment(look.align ?? .leading)
        var clip = look.clip == true
        switch node.content {
        case .column, .stack: vertical = .top
        case .scroll: (height, padding, clickable, vertical) = (nil, Insets(0), nil, .top)
        case .image:
            (width, height, clip) = (width ?? height ?? 16, height ?? width ?? 16, clip || look.fit == .fill)
            horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case .slider: (width, clickable) = (width ?? 120, nil)
        case .input: (width, clickable) = (width ?? 240, nil)
        case .progress: (width, height, background) = (width ?? 120, height ?? 6, nil)
        case .icon: horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case .row, .button, .text, .spacer: break
        }
        let shape = RoundedRectangle(cornerRadius: look.radius ?? 0, style: .continuous)
        return self
            .padding(EdgeInsets(padding))
            .frame(
                width: width.map { CGFloat($0) },
                height: height.map { CGFloat($0) },
                alignment: Alignment(horizontal: horizontal, vertical: vertical),
            )
            .frame(minWidth: look.minWidth.map { CGFloat($0) }, alignment: Alignment(horizontal: horizontal, vertical: vertical))
            .background {
                if let background {
                    shape.fill(Color(background))
                }
            }
            .material(look.material, radius: look.radius ?? 0)
            .appearance(look.colorScheme)
            .clipped(to: clip ? shape : nil)
            .overlay {
                if let border = look.border, let color = look.borderColor {
                    shape.strokeBorder(Color(color), lineWidth: border.width)
                }
            }
            .interactive(clickable, hovering: hovering, pressing: pressing) { perform($0, .null) }
            .dropShadow(look.shadow, look.shadowColor)
            .scaleEffect(look.scale ?? 1)
            .opacity(look.opacity ?? 1)
            .offset(x: look.x ?? 0, y: (look.offset ?? 0) + (look.y ?? 0))
            .transaction(value: node) { transaction in
                guard let animation = look.animation else { return }
                transaction.animation = reduceMotion ? nil : SwiftUI.Animation(animation, duration: look.duration)
            }
            .transition(AnyTransition(look.transition ?? .opacity))
            .zIndex(look.zIndex ?? 0)
            .layoutPriority(node.kind == .spacer ? -1 : 0)
    }

    @ViewBuilder func dropShadow(_ shadow: Shadow?, _ color: RGBA?) -> some View {
        if let shadow, let color {
            self.shadow(color: Color(color), radius: shadow.radius, y: shadow.y)
        } else {
            self
        }
    }

    @ViewBuilder func appearance(_ scheme: GaryCore.ColorScheme?) -> some View {
        if let scheme {
            environment(\.colorScheme, scheme == .dark ? .dark : .light)
        } else {
            self
        }
    }

    @ViewBuilder func clipped(to shape: RoundedRectangle?) -> some View {
        if let shape {
            clipShape(shape)
        } else {
            self
        }
    }

    @ViewBuilder func material(_ material: GaryCore.Material?, radius: Double) -> some View {
        switch material {
        case .vibrant: background(Vibrancy(radius: radius))
        case .glass: glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        case .some(.none), nil: self
        }
    }

    @ViewBuilder func card(_ card: Card?) -> some View {
        if let card {
            let shape = RoundedRectangle(cornerRadius: card.radius)
            background {
                if let background = card.look.background {
                    shape.fill(Color(background))
                }
            }
            .material(card.look.material, radius: card.radius)
            .clipShape(shape)
            .overlay {
                if let border = card.border {
                    shape.strokeBorder(Color(border), lineWidth: 1)
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder func interactive(
        _ action: String?,
        hovering: Binding<Bool>?,
        pressing: Binding<Bool>?,
        _ perform: @escaping (String) -> Void,
    ) -> some View {
        if action == nil, hovering == nil {
            self
        } else {
            contentShape(Rectangle())
                .onHover { inside in hovering?.wrappedValue = inside }
                .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { down in
                    guard let action else { return }
                    pressing?.wrappedValue = down
                    if down {
                        perform(action)
                    }
                })
        }
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
