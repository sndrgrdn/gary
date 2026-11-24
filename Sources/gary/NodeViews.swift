import AppKit
import Combine
import GaryCore
import SwiftUI

final class MountedTree: ObservableObject {
    @Published var root: Node
    @Published var theme: Theme
    @Published var fit: Fit?
    @Published var card: Card?
    @Published var backdrop = false
    @Published var inspection: FrameRecorder?
    @Published var opening = 0
    @Published var revealing: String?
    var plugin: PluginID?

    init(root: Node, theme: Theme) {
        self.root = root
        self.theme = theme
    }
}

final class TreeHostingView: NSHostingView<TreeView> {
    var tree: MountedTree {
        rootView.tree
    }

    convenience init(tree: MountedTree, onAction: @escaping ActionHandler, tooltipPanel: TooltipPanel? = nil, onDismiss: @escaping () -> Void) {
        self.init(rootView: TreeView(tree: tree, onAction: onAction, tooltipPanel: tooltipPanel, onDismiss: onDismiss))
        sizingOptions = [.intrinsicContentSize]
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
    let tooltipPanel: TooltipPanel?
    let onDismiss: () -> Void

    var body: some View {
        let root = NodeView(node: tree.root, theme: tree.theme, path: tree.inspection == nil ? nil : "")
            .environment(\.nodeAction, onAction)
            .environment(\.frameRecorder, tree.inspection)
            .environment(\.tooltipPanel, tooltipPanel)
            .environment(\.pluginID, tree.plugin)
            .environment(\.opening, tree.opening)
            .environment(\.revealing, tree.revealing)
        if let fit = tree.fit, tree.backdrop {
            fit {
                ZStack {
                    Color.black.opacity(0.005).onTapGesture(perform: onDismiss).accessibilityAddTraits(.isButton)
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
    var borderWidth: Double
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

struct NodeChild: Identifiable {
    let id: Node.ChildID
    let node: Node
}

extension Node {
    var identifiedChildren: [NodeChild] {
        zip(childIDs, children).map(NodeChild.init)
    }

    var scrolls: Bool {
        if case .scroll = content {
            true
        } else {
            false
        }
    }
}

struct NodeView: View {
    let node: Node
    let theme: Theme
    var axis: Axis?
    var path: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hovering = State(initialValue: false)
    private let pressing = State(initialValue: false)
    private let anchor = State(initialValue: GestureAnchor())

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
        let look = theme.resolve(node.style, props, hover: hover)
        let box = NodeBox(look, node)
        return boxed(content(look, box), box, look)
            .probed(path, look)
            .modifier(VisualEffects(look, node))
            .transaction(value: look.animation == nil ? nil : node) { transaction in
                guard let animation = look.animation, !transaction.disablesAnimations else { return }
                transaction.animation = reduceMotion ? nil : SwiftUI.Animation(animation, duration: look.duration)
            }
            .transition(AnyTransition(look.transition ?? .opacity))
            .zIndex(look.zIndex ?? 0)
            .layoutPriority(node.kind == .spacer ? -1 : 0)
    }

    private func boxed(_ content: some View, _ box: NodeBox, _ look: ResolvedStyle) -> some View {
        let tracksHover = node.hovered != nil || node.kind == .button
        let fade: SwiftUI.Animation? = reduceMotion || node.kind == .button ? nil : .easeOut(duration: 0.15)
        let gestures = anchor.wrappedValue
        let shape = RoundedRectangle(cornerRadius: look.radius ?? 0, style: .continuous)
        return content.padding(EdgeInsets(box.padding))
            .frame(width: box.width.map { CGFloat($0) }, height: box.height.map { CGFloat($0) }, alignment: box.alignment)
            .minWidth(look.minWidth, alignment: box.alignment)
            .background {
                if let background = box.background {
                    shape.fill(AnyShapeStyle(background))
                }
            }
            .material(look.material, radius: look.radius ?? 0)
            .appearance(look.colorScheme)
            .clipShape(BoxClip(radius: look.radius ?? 0, clips: box.clip))
            .overlay {
                if let border = look.border, let color = look.borderColor {
                    shape.strokeBorder(Color(color), lineWidth: border.width)
                }
            }
            .overlay {
                if !node.actions.isEmpty || node.tooltip != nil {
                    GestureCatcher(actions: node.actions, scrolls: node.scrolls, tooltip: node.tooltip, anchor: gestures)
                }
            }
            .interactive(
                box.action,
                hovering: tracksHover ? animated(hovering, fade) : nil,
                pressing: node.pressed != nil ? animated(pressing, fade) : nil,
            ) { _ in gestures.view?.send(.click, .null) }
            .dropShadow(look.shadow, look.shadowColor, always: node.hovered != nil || node.pressed != nil || node.kind == .button)
    }

    private func animated(_ state: State<Bool>, _ animation: SwiftUI.Animation?) -> Binding<Bool> {
        Binding(get: { state.wrappedValue }, set: { next in withAnimation(animation) { state.wrappedValue = next } })
    }

    @ViewBuilder private func content(_ look: ResolvedStyle, _ box: NodeBox) -> some View {
        let gap = look.gap ?? theme.spacing.item
        switch node.content {
        case .row:
            RowLayout(spacing: gap) { Children(node: node, theme: theme, axis: .horizontal, path: path) }
        case .column:
            VStack(alignment: .leading, spacing: gap) { Children(node: node, theme: theme, axis: .vertical, path: path) }
        case .stack:
            ZStack(alignment: .topLeading) { Children(node: node, theme: theme, axis: nil, path: path) }
        case .scroll:
            ScrollNode(node: node, theme: theme, gap: gap, padding: look.padding ?? Insets(0), maxHeight: look.height, path: path)
        case let .text(text):
            TextNode(text: text, look: look, lines: theme.textLines)
        case let .icon(symbol):
            Image(systemName: symbol).font(.system(size: look.font.size, weight: .init(look.font.weight))).foregroundStyle(Color(look.color))
        case let .image(path):
            ImageNode(
                path: path,
                fit: look.fit ?? .fit,
                size: CGSize(width: box.width ?? 0, height: box.height ?? 0),
                tint: node.props.color == nil ? nil : Color(look.color),
                arrival: reduceMotion ? nil : look.animation.flatMap { SwiftUI.Animation($0, duration: look.duration) },
                transition: AnyTransition(look.transition ?? .opacity),
            )
        case let .slider(fraction, release):
            SliderNode(
                fraction: fraction,
                width: box.width ?? 0,
                action: node.actions[.click],
                release: release,
                tint: node.props.color == nil ? nil : Color(look.color),
            )
        case let .progress(fraction):
            Advancing(fraction: fraction, width: box.width ?? 0) { value in ProgressBar(value: value, look: look) }
        case let .input(input):
            InputNode(input: input, font: nsFont(look.font), color: Color(look.color))
        case .spacer:
            SpacerNode(axis: axis)
        case .button:
            HStack(alignment: .center, spacing: gap) { Children(node: node, theme: theme, axis: .horizontal, path: path) }.fixedSize()
        case let .shape(shape):
            ShapeNode(shape: shape, theme: theme, color: look.color)
        case let .chart(chart):
            ChartNode(chart: chart, theme: theme, color: look.color, font: nsFont(look.font))
        case let .grid(_, columns):
            GridNode(node: node, columns: columns, theme: theme, gap: gap, align: look.align ?? .leading, path: path)
        case let .shader(shader):
            ShaderNode(shader: shader)
        }
    }
}

private struct SpacerNode: View {
    let axis: Axis?

    var body: some View {
        switch axis {
        case .horizontal: HStack(spacing: 0) { Spacer(minLength: 0) }
        case .vertical: VStack(spacing: 0) { Spacer(minLength: 0) }
        case nil: Spacer(minLength: 0)
        }
    }
}

private struct Children: View {
    let node: Node
    let theme: Theme
    let axis: Axis?
    let path: String?

    var body: some View {
        ForEach(node.identifiedChildren) { child in NodeView(node: child.node, theme: theme, axis: axis, path: path?.child(child.id)) }
    }
}

private extension View {
    func minWidth(_ minWidth: Double?, alignment: Alignment) -> some View {
        MinWidth(minWidth: minWidth, alignment: alignment) { self }
    }

    @ViewBuilder func dropShadow(_ shadow: Shadow?, _ color: RGBA?, always: Bool) -> some View {
        if always || shadow != nil && color != nil {
            self.shadow(color: color.map { Color($0) } ?? .clear, radius: shadow?.radius ?? 0, y: shadow?.y ?? 0)
        } else {
            self
        }
    }

    func appearance(_ scheme: GaryCore.ColorScheme?) -> some View {
        transformEnvironment(\.colorScheme) { inherited in
            if let scheme {
                inherited = scheme == .dark ? .dark : .light
            }
        }
    }

    @ViewBuilder func material(_ material: GaryCore.Material?, radius: Double) -> some View {
        let vibrant = background {
            if material == .vibrant {
                Vibrancy(radius: radius)
            }
        }
        if material == .glass {
            vibrant.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            vibrant
        }
    }

    @ViewBuilder func card(_ card: Card?) -> some View {
        if let card {
            let shape = RoundedRectangle(cornerRadius: card.radius)
            background {
                if let background = card.look.background {
                    shape.fill(AnyShapeStyle(background))
                }
            }
            .material(card.look.material, radius: card.radius)
            .clipShape(shape)
            .overlay {
                if let border = card.border {
                    shape.strokeBorder(Color(border), lineWidth: card.borderWidth)
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
                .onLongPressGesture(minimumDuration: 0) {
                    if let action {
                        perform(action)
                    }
                } onPressingChanged: { down in
                    if action != nil {
                        pressing?.wrappedValue = down
                    }
                }
        }
    }
}
