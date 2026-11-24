import AppKit
import GaryCore
import SwiftUI

struct MountKey: Hashable {
    let slot: SlotKey
    let surface: String
    let display: String
}

final class Screens {
    private(set) var displays: [DisplayInfo] = []
    private(set) var bars = PerDisplay<BarWindow>()
    private(set) var windows: [MountKey: SurfaceWindow] = [:]
    private(set) var mounts: [MountKey: TreeHostingView] = [:]
    private var barsAside: [String: Bool] = [:]
    private var asideTimer: Timer?
    private var clickMonitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private let parked = ParkedMounts()
    let tooltipPanel: TooltipPanel
    let theme: CurrentTheme
    let setup: PluginSetup
    let slots: PluginSlots<PluginRuntime>
    let hide: (MountKey, Trace) -> Void

    init(theme: CurrentTheme, setup: PluginSetup, slots: PluginSlots<PluginRuntime>, hide: @escaping (MountKey, Trace) -> Void) {
        self.theme = theme
        self.setup = setup
        self.slots = slots
        self.hide = hide
        tooltipPanel = TooltipPanel(theme: theme.value)
    }

    func refresh(builtinBar: Bool) -> DisplayChange? {
        let theme = theme.value
        let next = NSScreen.screens.enumerated().map { $1.display(index: $0, theme: theme) }
        let change = DisplayChange(from: displays, to: next)
        displays = next
        let appearance = appearance
        let level = SurfaceLevels.bar
        let barChange = bars.sync(builtinBar ? next : [], open: { [weak self] display in
            let bar = BarWindow(display: display, level: level)
            watchTopEdge(of: bar.content) { [weak self, weak bar] in
                if let bar {
                    self?.pointerReachedTop(bar.display.id)
                }
            }
            bar.panel.appearance = appearance
            bar.layout(theme: theme)
            return bar
        }, update: { bar, display in
            bar.display = display
            bar.layout(theme: theme)
        }, close: { $0.close() })
        guard !change.isEmpty || !barChange.isEmpty else { return nil }
        for key in mounts.keys where change.removed.contains(key.display) || (key.slot.kind == .barWidget && bars[key.display] == nil) {
            unmount(key)
        }
        return change
    }

    func pointerReachedTop(_ id: String) {
        guard setup.config.revealMenuBar, !SystemState.saved.menuBarHidden, barsAside[id] == nil,
              let display = displays.first(where: { $0.id == id }) else { return }
        barsAside[id] = NativeMenuBar.revealed(on: display.frame)
        applyBarLevel(id)
        log("bar on \(id.prefix(8)) hides so the macOS menu bar can reveal")
        guard asideTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.returnBarsAside() } }
        RunLoop.main.add(timer, forMode: .common)
        asideTimer = timer
    }

    private func returnBarsAside() {
        let pointer = NSEvent.mouseLocation
        for (id, menuBarWasShown) in barsAside {
            if let display = displays.first(where: { $0.id == id }), setup.config.revealMenuBar, !SystemState.saved.menuBarHidden {
                let band = NSRect(x: display.frame.minX, y: display.frame.maxY - display.band, width: display.frame.width, height: display.band)
                if NSMouseInRect(pointer, band, false) || (!menuBarWasShown && NativeMenuBar.revealed(on: display.frame)) {
                    continue
                }
            }
            barsAside[id] = nil
            applyBarLevel(id)
            log("bar on \(id.prefix(8)) returns over the macOS menu bar")
        }
        if barsAside.isEmpty {
            asideTimer?.invalidate()
            asideTimer = nil
        }
    }

    func barLevel(_ display: String) -> Int {
        barsAside[display] == nil ? SurfaceLevels.bar : SurfaceLevels.barAside
    }

    private func applyBarLevel(_ display: String) {
        let aside = barsAside[display] != nil
        let panels = [bars[display]?.panel].compactMap(\.self) + windows.filter { $0.key.slot.kind == .bar && $0.key.display == display }
            .map(\.value.panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = theme.value.motion.fade
            for panel in panels {
                panel.level = NSWindow.Level(rawValue: barLevel(display))
                panel.animator().alphaValue = aside ? 0 : 1
            }
        }
    }

    func mount(_ key: MountKey, _ tree: Node?) -> Bool {
        let slotKey = key.slot
        let onAction: ActionHandler = { [weak self] event in self?.perform(event, slotKey) }
        let changed: Bool
        var kept: ParkedMount?
        if let view = mounts[key] {
            changed = view.apply(tree)
            if tree == nil {
                tooltipPanel.hide(inside: view)
            }
        } else {
            guard let tree else { return false }
            kept = parked.take(key)
            if let kept {
                kept.view.reopen(tree, theme: theme(for: slotKey.kind))
                mounts[key] = kept.view
            } else {
                let mounted = MountedTree(root: tree, theme: theme(for: slotKey.kind))
                mounted.plugin = slotKey.id
                mounts[key] = TreeHostingView(tree: mounted, onAction: onAction, tooltipPanel: tooltipPanel) { [weak self] in
                    self?.hide(key, Trace("click-outside"))
                }
            }
            changed = true
        }
        place(key, reopening: kept?.window)
        return changed
    }

    func place(_ key: MountKey, reopening kept: SurfaceWindow? = nil) {
        guard let view = mounts[key], let slot = slots[key.slot] else { return }
        if key.slot.kind == .barWidget {
            placeInBar(key)
            return
        }
        guard let display = displays.first(where: { $0.id == key.display }) else { return }
        let window = windows[key] ?? kept ?? SurfaceWindow()
        let isNew = windows[key] == nil
        windows[key] = window
        if isNew {
            window.panel.appearance = appearance
        }
        window.setContent(view)
        if key.slot.kind == .bar {
            var spec = SurfaceSpec.defaults(for: .bar)
            spec.anchors = Edges(top: true, bottom: false, left: true, right: true)
            spec.height = .points(display.band)
            spec.exclusionMode = .ignore
            window.place(spec, on: display, origin: nil, level: barLevel(display.id), theme: theme.value)
        } else if let spec = slot.surfaces[key.surface] {
            window.place(spec, on: display, origin: slot.shown[key.surface]?.origin, level: SurfaceLevels.level(spec.layer), theme: theme.value)
        }
        if isNew {
            open(window, key, focusable: slot.surfaces[key.surface]?.focusable == true)
        }
    }

    func focus(_ window: SurfaceWindow, _ mount: MountKey) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() {
            previousApp = front
        }
        window.panel.onKey = { [weak self] key in self?.keyPressed(key, mount) }
        if mount.slot.kind == .menu {
            window.panel.onResignKey = { [weak self] in
                if !ControlCenter.isOpen.load(ordering: .sequentiallyConsistent) {
                    self?.hide(mount, Trace("resign-key"))
                }
            }
        }
        window.focus()
    }

    func unmount(_ key: MountKey) {
        guard let view = mounts.removeValue(forKey: key) else { return }
        tooltipPanel.hide(inside: view)
        guard let window = windows.removeValue(forKey: key) else {
            view.removeFromSuperview()
            return
        }
        let hadFocus = window.panel.isKeyWindow
        if key.slot.kind.isSurface {
            parked.park(key, ParkedMount(window: window, view: view), fade: fade(key.slot))
        } else {
            window.panel.close()
        }
        if hadFocus {
            returnFocus()
        }
    }

    private func returnFocus() {
        guard !windows.values.contains(where: \.panel.isKeyWindow) else { return }
        NSApp.deactivate()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApp?.activate()
        }
        previousApp = nil
        if tracing {
            DispatchQueue.main.async {
                log(
                    "focus returned active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")",
                )
            }
        }
    }

    func watchClicks() {
        let open = windows.keys.contains { $0.slot.kind == .menu }
        guard open == clickMonitors.isEmpty else { return }
        if !open {
            for monitor in clickMonitors {
                NSEvent.removeMonitor(monitor)
            }
            clickMonitors = []
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.clicked(at: NSEvent.mouseLocation) },
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.clicked(at: event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
                return event
            },
        ].compactMap(\.self)
    }
}

extension TreeHostingView {
    func apply(_ root: Node?) -> Bool {
        let changed = isHidden != (root == nil)
        isHidden = root == nil
        guard let root, root != tree.root else { return changed }
        tree.root = root
        return true
    }

    func reopen(_ root: Node, theme: Theme) {
        isHidden = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tree.root = root
            tree.theme = theme
            tree.opening += 1
        }
    }
}
