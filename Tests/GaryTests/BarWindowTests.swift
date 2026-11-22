import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct BarWindowTests {
    private static let theme = try? Theme.parse(
        JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json"))),
        palette: Palette(nil, system: .dark),
    ).inBar

    private func view(_ text: String, theme: Theme) -> TreeHostingView {
        TreeHostingView(
            tree: MountedTree(root: Node(.text(text)), theme: theme),
            onAction: { _ in Issue.record("unexpected action") },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
    }

    private func minX(_ view: NSView, in bar: BarWindow) -> CGFloat {
        bar.content.layoutSubtreeIfNeeded()
        return view.convert(view.bounds, to: nil).minX
    }

    @Test func `a bar widget that renders null leaves no gap and comes back with one when it renders a node`() throws {
        let theme = try #require(Self.theme)
        let bar = BarWindow(display: display, level: 0)
        defer { bar.close() }
        bar.layout(theme: theme)
        let clock = view("12:00", theme: theme)
        let indicator = view("●", theme: theme)
        bar.setSection(.center, [clock])
        let alone = minX(clock, in: bar)

        _ = indicator.apply(nil)
        bar.setSection(.center, [indicator, clock])
        #expect(minX(clock, in: bar) == alone)

        #expect(indicator.apply(Node(.text("●"))))
        let shown = minX(clock, in: bar)
        let gap: Double = shown - indicator.convert(indicator.bounds, to: nil).maxX
        #expect(gap == theme.spacing.section)

        #expect(indicator.apply(nil))
        #expect(minX(clock, in: bar) == alone)
    }
}
