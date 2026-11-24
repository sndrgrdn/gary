import GaryCore
import SwiftUI

struct ScrollNode: View {
    let node: Node
    let theme: Theme
    let gap: Double
    let padding: Insets
    let maxHeight: Double?
    let path: String?
    @Environment(\.opening) private var opening
    @Environment(\.revealing) private var revealing

    var body: some View {
        let revealed = node.revealedChild.map { node.childIDs[$0] }
        ScrollFit(maxHeight: maxHeight) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: gap) {
                        ForEach(node.identifiedChildren) { child in
                            NodeView(node: child.node, theme: theme, axis: .vertical, path: path?.child(child.id)).id(child.id)
                        }
                    }
                    .padding(EdgeInsets(padding))
                    .id("top")
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: opening) {
                    proxy.scrollTo("top", anchor: .top)
                    if let revealed {
                        proxy.scrollTo(revealed)
                    }
                }
                .onChange(of: revealed, initial: true) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id) }
                }
                .onChange(of: revealing) { _, action in
                    guard let action, let index = node.children.firstIndex(where: { $0.has(action) }) else { return }
                    proxy.scrollTo(node.childIDs[index])
                }
            }
        }
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
