import AppKit
import GaryCore

extension Shell {
    func present(_ slot: PluginSlot, _ output: RuntimeOutput, _ trace: Trace) {
        if slot.key.kind.isSurface, !slot.visible {
            return
        }
        var timings = trace.timings
        let changes = measure(.apply, &timings) {
            slot.surfaces = output.surfaces
            var changes: [MountKey: Bool] = [:]
            for (surface, trees) in output.trees where !slot.key.kind.isSurface || slot.shown[surface] != nil {
                for (display, tree) in trees {
                    let key = MountKey(slot: slot.key, surface: surface, display: display)
                    changes[key] = mount(key, tree)
                }
            }
            for key in mounts.keys where key.slot == slot.key && output.trees[key.surface]?[key.display] == nil {
                unmount(key)
            }
            return changes
        }
        timings.merge(commitFrame())
        guard tracing else { return }
        let end = now()
        for (key, changed) in changes {
            log(String(
                format: "commit plugin=%@ surface=%@ display=%@ cause=%@ since_ms=%.3f changed=%d %@ tree=%@",
                key.slot.id.rawValue,
                key.surface,
                key.display,
                trace.cause,
                (end - trace.start) * 1000,
                changed ? 1 : 0,
                timings.fields,
                output.trees[key.surface]?[key.display]?.summary ?? "",
            ))
        }
    }

    private func mount(_ key: MountKey, _ tree: Node) -> Bool {
        let slotKey = key.slot
        let onAction: ActionHandler = { [weak self] event in self?.perform(event, slotKey) }
        let changed: Bool
        if let view = mounts[key] {
            changed = view.tree.root != tree
            if changed {
                view.tree.root = tree
            }
        } else {
            let mounted = MountedTree(root: tree, theme: theme(for: slotKey.kind))
            mounted.plugin = slotKey.id
            mounts[key] = TreeHostingView(tree: mounted, onAction: onAction, tooltipPanel: tooltipPanel) { [weak self] in
                self?.hide(key, Trace("click-outside"))
            }
            changed = true
        }
        place(key)
        return changed
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
        } else if let spec = slot.surfaces[key.surface] {
            window.place(spec, on: display, origin: slot.shown[key.surface]?.origin, level: SurfaceLevels.level(spec.layer), theme: theme)
        }
        if isNew {
            open(window, key, focusable: slot.surfaces[key.surface]?.focusable == true)
        }
    }

    private func placeInBar(_ key: MountKey) {
        guard let bar = bars[key.display] else { return }
        for (section, ids) in resolution.bar where ids.contains(key.slot.id) {
            bar.setSection(
                section,
                ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), surface: key.surface, display: key.display)] },
            )
        }
    }

    private func open(_ window: SurfaceWindow, _ key: MountKey, focusable: Bool) {
        if key.slot.kind == .bar {
            watchTopEdge(of: window.card) { [weak self] in self?.pointerReachedTop(key.display) }
        }
        window.show(fade: fade(key.slot))
        if key.slot.kind.isSurface {
            let slotKey = key.slot
            window.panel.onScroll = { [weak self] event in self?.slots[slotKey]?.runtime?.scroll(event) }
        }
        if key.slot.kind.isSurface, focusable {
            focus(window, key)
        }
        watchClicks()
    }

    private func focus(_ window: SurfaceWindow, _ mount: MountKey) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() {
            previousApp = front
        }
        window.panel.onKey = { [weak self] key in self?.keyPressed(key, mount) }
        if mount.slot.kind == .menu {
            window.panel.onResignKey = { [weak self] in self?.hide(mount, Trace("resign-key")) }
        }
        window.focus()
    }

    private func hide(_ mount: MountKey, _ trace: Trace) {
        guard let slot = slots[mount.slot] else { return }
        _ = hide(mount.surface, in: slot, trace)
    }

    private func keyPressed(_ key: String, _ mount: MountKey) {
        if tracing {
            log("key plugin=\(mount.slot) surface=\(mount.surface) key=\(key)")
        }
        slots[mount.slot]?.runtime?.key(key) { [weak self] in
            if mount.slot.kind.hides(onUnhandled: key) {
                self?.hide(mount, Trace("escape"))
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
        let menus = windows.keys.filter { $0.slot.kind == .menu }
        for menu in menus where !windows.contains(where: { $0.key.slot == menu.slot && $0.key.surface == menu.surface && $0.value.contains(point) }) {
            hide(menu, Trace("click-outside"))
        }
    }

    func unmount(_ slot: SlotKey, surface: String? = nil) {
        for key in mounts.keys where key.slot == slot && (surface == nil || key.surface == surface) {
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
        case let .row(children), let .column(children), let .stack(children), let .scroll(children, _), let .button(children, _),
             let .grid(children, _):
            children.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        case let .text(value), let .icon(value), let .image(value): value.replacingOccurrences(of: " ", with: "_") + ":" + (style ?? "default")
        case let .slider(value, _), let .progress(value): "\(kind.rawValue)=\(value.value)"
        case let .input(input): "input=\(input.value)"
        case .spacer: ""
        case .shape, .chart, .shader: kind.rawValue
        }
    }
}
