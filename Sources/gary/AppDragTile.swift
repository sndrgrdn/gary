import AppKit
import GaryCore

final class AppDragTile {
    static var theme: Theme?
    private static var current: AppDragTile?

    private let panel = makeSurfacePanel(level: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
    private let permission: Permission
    private var timer: Timer?
    private var probing = false
    private var settingsSeen = false
    private let opened = Date()

    static func show(until permission: Permission) {
        current?.close()
        current = AppDragTile(permission: permission)
    }

    private init(permission: Permission) {
        self.permission = permission
        let theme = Self.theme
        let look = theme?.style("surface")
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = (look?.background.map { NSColor($0) } ?? .windowBackgroundColor).cgColor
        card.layer?.cornerRadius = look?.radius ?? 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = theme?.color("border").map { NSColor($0).cgColor }

        let icon = DraggableAppIcon()
        let label = NSTextField(wrappingLabelWithString: "Drag Gary into the \(permission.name) list in System Settings.")
        label.font = .systemFont(ofSize: 13)
        label.textColor = theme.map { NSColor($0.resolve(nil).color) } ?? .labelColor
        label.preferredMaxLayoutWidth = 190
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: nil, action: nil)
        close.isBordered = false
        close.contentTintColor = theme?.color("dim").map { NSColor($0) } ?? .secondaryLabelColor
        let row = NSStackView(views: [icon, label, close])
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor), row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor), row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56),
        ])
        panel.contentView = card
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: theme?.mode == .light ? .aqua : .darkAqua)
        panel.setContentSize(card.fittingSize)
        close.target = self
        close.action = #selector(closeClicked)
        place()
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func closeClicked() {
        close()
    }

    private func close() {
        timer?.invalidate()
        panel.close()
        if Self.current === self {
            Self.current = nil
        }
    }

    private func tick() {
        let settings = Self.settingsWindow()
        if settings != nil {
            settingsSeen = true
        }
        if settingsSeen && settings == nil || Date().timeIntervalSince(opened) > 300 {
            close()
            return
        }
        place(beside: settings)
        guard !probing else { return }
        probing = true
        let permission = permission
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let granted = freshGrants([permission]).contains(permission)
            DispatchQueue.main.async {
                self?.probing = false
                if granted {
                    self?.close()
                }
            }
        }
    }

    private func place(beside settings: CGRect? = AppDragTile.settingsWindow()) {
        guard let screen = NSScreen.screens.first(where: { settings.map($0.frame.intersects) ?? false }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let settings {
            origin = CGPoint(x: settings.midX - size.width / 2, y: settings.minY - size.height - 12)
            if origin.y < visible.minY {
                origin.y = settings.minY + 16
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 80)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private static func settingsWindow() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let settings = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
        return windows.lazy
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t).map(settings.contains) == true && $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .filter { $0.width > 200 && $0.height > 200 }
            .map { CGRect(x: $0.minX, y: mainHeight - $0.maxY, width: $0.width, height: $0.height) }
            .first
    }
}

private final class DraggableAppIcon: NSImageView, NSDraggingSource {
    init() {
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = Bundle.main.bundlePath
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
