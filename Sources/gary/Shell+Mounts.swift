import AppKit
import GaryCore

extension Shell {
    func present(_ slot: PluginSlot, _ output: RuntimeOutput, _ trace: Trace) {
        if slot.key.kind.isSurface, !slot.visible {
            return
        }
        slot.surface = output.surface
        for (display, tree) in output.trees {
            mount(slot, display, tree, trace)
        }
        for key in mounts.keys where key.slot == slot.key && output.trees[key.display] == nil {
            unmount(key)
        }
        commitFrame()
    }

    private func mount(_ slot: PluginSlot, _ display: String, _ tree: Node, _ trace: Trace) {
        let key = MountKey(slot: slot.key, display: display)
        let slotKey = slot.key
        let onAction: ActionHandler = { [weak self] event in self?.perform(event, slotKey) }
        let started = now()
        let changed: Bool
        if let view = mounts[key] {
            changed = view.tree.root != tree
            if changed {
                view.tree.root = tree
            }
        } else {
            mounts[key] = TreeHostingView(
                tree: MountedTree(root: tree, theme: theme(for: slot.key.kind)), onAction: onAction, tooltipPanel: tooltipPanel,
            ) { [weak self] in
                _ = self?.hide(slotKey.id, Trace("click-outside"))
            }
            changed = true
        }
        place(key)
        if tracing {
            let end = now()
            log(String(
                format: "commit plugin=%@ display=%@ cause=%@ since_ms=%.3f apply_ms=%.3f changed=%d tree=%@",
                slot.key.id.rawValue,
                display,
                trace.cause,
                (end - trace.start) * 1000,
                (end - started) * 1000,
                changed ? 1 : 0,
                tree.summary,
            ))
        }
    }

    func theme(for kind: PluginKind) -> Theme {
        kind == .bar || kind == .barWidget ? theme.inBar : theme
    }

    func place(_ key: MountKey) {
        guard let view = mounts[key], let slot = slots[key.slot] else { return }
        if key.slot.kind == .barWidget {
            placeInBar(key)
            return
        }
        guard let display = displays.first(where: { $0.id == key.display }) else { return }
        let window = windows[key] ?? SurfaceWindow()
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
            window.place(spec, on: display, origin: nil, level: barLevel(display.id), theme: theme)
        } else if let spec = slot.surface {
            window.place(spec, on: display, origin: slot.origin, level: levels.level(spec.layer), theme: theme)
        }
        if isNew {
            open(window, key, slot)
        }
    }

    private func placeInBar(_ key: MountKey) {
        guard let bar = bars[key.display] else { return }
        for (section, ids) in resolution.bar where ids.contains(key.slot.id) {
            bar.setSection(section, ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), display: key.display)] })
        }
    }

    private func open(_ window: SurfaceWindow, _ key: MountKey, _ slot: PluginSlot) {
        if key.slot.kind == .bar {
            watchTopEdge(of: window.card) { [weak self] in self?.pointerReachedTop(key.display) }
        }
        window.show(fade: fade(key.slot))
        if key.slot.kind.isSurface {
            let slotKey = key.slot
            window.panel.onScroll = { [weak self] event in self?.slots[slotKey]?.runtime?.scroll(event) }
        }
        if key.slot.kind.isSurface, slot.surface?.focusable == true {
            focus(window, key.slot)
        }
        watchClicks()
    }

    private func focus(_ window: SurfaceWindow, _ slot: SlotKey) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() {
            previousApp = front
        }
        window.panel.onKey = { [weak self] key in self?.keyPressed(key, slot) }
        if slot.kind == .menu {
            window.panel.onResignKey = { [weak self] in _ = self?.hide(slot.id, Trace("resign-key")) }
        }
        window.focus()
    }

    private func keyPressed(_ key: String, _ slot: SlotKey) {
        if tracing {
            log("key plugin=\(slot) key=\(key)")
        }
        slots[slot]?.runtime?.key(key) { [weak self] in
            if slot.kind.hides(onUnhandled: key) {
                _ = self?.hide(slot.id, Trace("escape"))
            }
        }
    }

    func unmount(_ key: MountKey) {
        if let view = mounts[key] {
            tooltipPanel.hide(inside: view)
        }
        if let window = windows.removeValue(forKey: key) {
            let hadFocus = window.panel.isKeyWindow
            window.close(fade: fade(key.slot))
            mounts[key] = nil
            if hadFocus {
                returnFocus()
            }
        } else {
            mounts.removeValue(forKey: key)?.removeFromSuperview()
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

    private func fade(_ slot: SlotKey) -> Double {
        slot.kind.isSurface ? theme.motion.fade : 0
    }

    private func watchClicks() {
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
                self?.clicked(at: NSEvent.mouseLocation)
                return event
            },
        ].compactMap(\.self)
    }

    private func clicked(at point: NSPoint) {
        let menus = Set(windows.keys.filter { $0.slot.kind == .menu }.map(\.slot))
        for menu in menus where !windows.contains(where: { $0.key.slot == menu && $0.value.contains(point) }) {
            _ = hide(menu.id, Trace("click-outside"))
        }
    }

    func unmount(_ slot: SlotKey) {
        for key in mounts.keys where key.slot == slot {
            unmount(key)
        }
        if slot.kind == .barWidget {
            arrangeBars()
        }
        watchClicks()
    }
}

extension Node {
    var summary: String {
        switch content {
        case let .row(children), let .column(children), let .stack(children), let .scroll(children, _), let .button(children, _):
            children.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        case let .text(value), let .icon(value), let .image(value): value.replacingOccurrences(of: " ", with: "_") + ":" + (style ?? "default")
        case let .slider(value), let .progress(value): "\(kind.rawValue)=\(value)"
        case let .input(input): "input=\(input.value)"
        case .spacer: ""
        }
    }
}
