import AppKit
import GaryCore
import SwiftUI

nonisolated extension Capability {
    static let toast = Capability(
        name: "toast",
        summary: """
        Show a toast: a card with a title, an optional body and an optional icon, which Gary draws with the theme's \
        `toast`, `toast-title`, `toast-body`, and `toast-icon` styles at the top right of the display under the pointer. \
        Newer toasts stack above older ones, and Gary shows at most \(ToastStack.limit). A toast hides after `timeout` \
        seconds, \(Int(ToastRequest.defaultTimeout)) by default, or when the user clicks it, and the promise resolves with \
        which. A `timeout` of 0 keeps it until the click. The icon is either `icon`, an SF Symbol name, or `glyph`, text such \
        as a Nerd Font glyph drawn in the `toast-icon` style's font, or in the theme font that `font` names.
        """,
        types: """
        declare namespace Gary {
          type Toast = { title: string; body?: string; timeout?: number }
            & ({ icon?: string; glyph?: null; font?: null } | { icon?: null; glyph: string; font?: FontName })
          interface Host { toast(toast: Toast): Promise<"clicked" | "expired"> }
        }
        """,
        example: """
        export default {
          render() {
            return { type: "icon", symbol: "clock", action: "time" };
          },
          onAction() {
            const time = new Date().toTimeString().slice(0, 5);
            host.toast({ title: time, body: "Click to log it", icon: "clock" }).then((outcome) => {
              if (outcome === "clicked") host.log(`it was ${time}`);
            });
            host.toast({ title: "Saved", glyph: "\\u{F0193}", font: "icon" });
          },
        } satisfies Gary.BarWidget;
        """,
        install: { host, plugin in
            plugin.installAPI(host, nil, ["toast"]) { call in
                let request = try ToastRequest.parse(call)
                return .pending { finish in
                    DispatchQueue.main.async { ToastStack.shared.show(request) { finish(.success(.string($0.rawValue))) } }
                }
            }
        },
    )
}

nonisolated enum ToastOutcome: String {
    case clicked, expired
}

final class ToastStack {
    static let shared = ToastStack()
    nonisolated static let limit = 5

    var theme: Theme?
    private var cards: [ToastCard] = []
    private var screen: NSScreen?

    func show(_ request: ToastRequest, _ finish: @escaping @Sendable (ToastOutcome) -> Void) {
        guard let theme else {
            finish(.expired)
            return
        }
        if cards.isEmpty {
            screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
        let card = ToastCard(node: Self.node(request, theme), theme: theme, finish: finish)
        card.onClick = { [weak self, weak card] in
            if let card {
                self?.close(card, .clicked)
            }
        }
        if let timeout = request.timeout {
            card.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self, weak card] _ in
                MainActor.assumeIsolated {
                    if let card {
                        self?.close(card, .expired)
                    }
                }
            }
        }
        cards.insert(card, at: 0)
        for old in cards.dropFirst(Self.limit) {
            close(old, .expired)
        }
        arrange()
    }

    private static func node(_ request: ToastRequest, _ theme: Theme) -> Node {
        let lines = [Node(.text(request.title), style: "toast-title")] + (request.body.map { [Node(.text($0), style: "toast-body")] } ?? [])
        let icon = request.icon.map { node($0, theme) }
        return Node(.row([icon, Node(.column(lines), props: StyleProps(gap: 0))].compactMap(\.self)), style: "toast")
    }

    private static func node(_ icon: ToastRequest.Icon, _ theme: Theme) -> Node {
        switch icon {
        case let .symbol(symbol):
            return Node(.icon(symbol), style: "toast-icon")
        case let .glyph(glyph, font):
            let look = theme.resolve("toast-icon", StyleProps(font: font))
            return Node(
                .text(glyph),
                style: "toast-icon",
                props: StyleProps(width: look.width ?? (look.font.size * 1.2).rounded(), align: .center, font: font),
            )
        }
    }

    private func close(_ card: ToastCard, _ outcome: ToastOutcome) {
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: index)
        card.timer?.invalidate()
        card.finish(outcome)
        let panel = card.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
        arrange()
    }

    private var fade: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : theme?.motion.fade ?? 0
    }

    private func arrange() {
        guard let screen, let theme else { return }
        let display = screen.display(index: 0, theme: theme)
        let edge = theme.spacing.edge
        var top = display.frame.maxY - display.band - edge
        FrameLog.shared.arm(for: fade)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            for card in cards {
                let size = card.size
                let frame = NSRect(x: display.frame.maxX - edge - size.width, y: top - size.height, width: size.width, height: size.height)
                top = frame.minY - theme.spacing.item
                if card.panel.isVisible {
                    card.panel.animator().setFrame(frame, display: true)
                } else {
                    card.panel.setFrame(frame, display: true)
                    card.panel.alphaValue = 0
                    card.panel.orderFrontRegardless()
                    card.panel.animator().alphaValue = 1
                }
            }
        }
    }
}

private final class ToastCard: NSView {
    let panel = makeSurfacePanel(level: SurfaceLevels.level(.overlay))
    let finish: @Sendable (ToastOutcome) -> Void
    var onClick: (() -> Void)?
    var timer: Timer?
    private let content: NSHostingView<NodeView>

    init(node: Node, theme: Theme, finish: @escaping @Sendable (ToastOutcome) -> Void) {
        self.finish = finish
        content = NSHostingView(rootView: NodeView(node: node, theme: theme))
        content.sizingOptions = [.intrinsicContentSize]
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        panel.contentView = self
        panel.hasShadow = true
        panel.appearance = NSAppearance(theme.mode)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    var size: NSSize {
        content.layoutSubtreeIfNeeded()
        return content.intrinsicContentSize
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }
}
