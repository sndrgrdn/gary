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

nonisolated struct BoxClip: Shape {
    var radius: Double
    var clips: Bool

    func path(in rect: CGRect) -> Path {
        clips ? RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect) : Path(CGRect.infinite)
    }
}

struct RowLayout: Layout {
    var spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = sizes(proposal, subviews)
        return CGSize(width: sizes.map(\.width).reduce(0, +) + gaps(subviews), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes(ProposedViewSize(bounds.size), subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: size.width, height: bounds.height))
            x += size.width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGSize] {
        func widths(_ width: CGFloat?) -> [CGFloat] {
            subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).width }
        }
        func measured(_ given: [CGFloat]) -> [CGSize] {
            zip(subviews, given).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)) }
        }
        let ideal = widths(nil)
        guard let width = proposal.width else { return measured(ideal) }
        let target = width - gaps(subviews)
        let total = ideal.reduce(0, +)
        let most = widths(.infinity)
        let sizes = measured(target > total ? level(zip(ideal, most), to: target) : target < total ? level(zip(widths(0), ideal), to: target) : ideal)
        let unused = target - sizes.map(\.width).reduce(0, +)
        let spacers = most.count(where: { !$0.isFinite })
        guard unused > 0, spacers > 0 else { return sizes }
        return zip(sizes, most).map { size, most in
            most.isFinite ? size : CGSize(width: size.width + unused / CGFloat(spacers), height: size.height)
        }
    }

    private func level(_ ranges: Zip2Sequence<[CGFloat], [CGFloat]>, to target: CGFloat) -> [CGFloat] {
        func widths(_ cap: CGFloat) -> [CGFloat] {
            ranges.map { low, high in min(high, max(low, cap)) }
        }
        var low = CGFloat(0)
        var high = max(target, ranges.map(\.1).filter(\.isFinite).max() ?? 0)
        for _ in 0..<32 {
            let cap = (low + high) / 2
            if widths(cap).reduce(0, +) > target {
                high = cap
            } else {
                low = cap
            }
        }
        return widths(low)
    }
}

struct TextNode: View {
    let text: String
    let look: ResolvedStyle
    let lines: Int?

    var body: some View {
        let spills = look.width != nil && look.lines == nil && look.truncate == nil
        let font = nsFont(look.font)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        Self.text(text, overhang: ink.maxX - CTLineGetTypographicBounds(line, nil, nil, nil))
            .font(Font(font as CTFont)).foregroundStyle(Color(look.color))
            .multilineTextAlignment(TextAlignment(look.align ?? .leading))
            .lineLimit(look.lines ?? (look.width == nil ? lines : 1))
            .truncationMode(Text.TruncationMode(look.truncate ?? .tail))
            .fixedSize(horizontal: spills, vertical: true)
            .padding(.leading, max(0, -ink.minX))
    }

    private static func text(_ text: String, overhang: Double) -> Text {
        guard overhang > 0 else { return Text(verbatim: text) }
        var string = AttributedString(text)
        string[string.characters.index(before: string.endIndex)...].kern = overhang
        return Text(string)
    }
}
