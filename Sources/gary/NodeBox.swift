import GaryCore
import SwiftUI

struct NodeBox: Equatable {
    var width: Double?
    var height: Double?
    var padding: Insets
    var background: ResolvedPaint?
    var action: String?
    var alignment: Alignment
    var clip: Bool

    init(_ look: ResolvedStyle, _ node: Node) {
        width = look.width
        height = look.height
        padding = look.padding ?? Insets(0)
        background = look.background
        action = node.actions[.click]
        alignment = Alignment(horizontal: HorizontalAlignment(look.align ?? .leading), vertical: .center)
        clip = look.clip == true
        switch node.content {
        case .column, .stack: alignment.vertical = .top
        case .scroll: (height, padding, action, alignment.vertical) = (nil, Insets(0), nil, .top)
        case .image:
            (width, height, clip) = (width ?? height ?? 16, height ?? width ?? 16, clip || look.fit == .fill)
            alignment.horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case .slider: (width, action) = (width ?? 120, nil)
        case .input: (width, action) = (width ?? 240, nil)
        case .progress: (width, height, background) = (width ?? 120, height ?? 6, nil)
        case .icon: alignment.horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case let .shape(shape): (width, height) = (width ?? shape.viewBox.map(\.width) ?? 24, height ?? shape.viewBox.map(\.height) ?? 24)
        case .chart: (width, height) = (width ?? 60, height ?? 16)
        case .shader: (width, height) = (width ?? height ?? 100, height ?? width ?? 100)
        case .row, .button, .text, .spacer, .grid: break
        }
    }
}

struct MinWidth: Layout {
    var minWidth: Double?
    var alignment: Alignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let minWidth else { return child.sizeThatFits(proposal) }
        let width = proposal.width.map { max($0, CGFloat(minWidth)) }
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: max(minWidth, min(size.width, width ?? .infinity)), height: size.height)
    }

    func explicitAlignment(
        of _: HorizontalAlignment,
        in _: CGRect,
        proposal _: ProposedViewSize,
        subviews _: Subviews,
        cache _: inout (),
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(of _: VerticalAlignment, in _: CGRect, proposal _: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGFloat? {
        nil
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let child = subviews.first else { return }
        guard minWidth != nil else {
            child.place(at: bounds.origin, proposal: proposal)
            return
        }
        let anchor = UnitPoint(
            x: alignment.horizontal == .leading ? 0 : alignment.horizontal == .trailing ? 1 : 0.5,
            y: alignment.vertical == .top ? 0 : alignment.vertical == .bottom ? 1 : 0.5,
        )
        child.place(
            at: CGPoint(x: bounds.minX + bounds.width * anchor.x, y: bounds.minY + bounds.height * anchor.y),
            anchor: anchor,
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
        )
    }
}
