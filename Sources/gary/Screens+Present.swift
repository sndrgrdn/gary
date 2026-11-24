import AppKit
import GaryCore

extension Screens {
    func present(_ slot: SlotKey, _ output: RuntimeOutput) -> [MountKey: Bool] {
        let shown = slots[slot]?.shown ?? [:]
        var changes: [MountKey: Bool] = [:]
        for (surface, trees) in output.trees where !slot.kind.isSurface || shown[surface] != nil {
            for (display, tree) in trees {
                let key = MountKey(slot: slot, surface: surface, display: display)
                changes[key] = mount(key, tree)
            }
        }
        for key in mounts.keys where key.slot == slot && output.trees[key.surface]?.keys.contains(key.display) != true {
            unmount(key)
        }
        return changes
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

    func restyle(builtinBar: Bool) -> DisplayChange? {
        tooltipPanel.theme = theme.value
        for panel in panels {
            panel.appearance = appearance
        }
        let change = refresh(builtinBar: builtinBar)
        for bar in bars.surfaces.values {
            bar.layout(theme: theme.value)
        }
        for (key, view) in mounts {
            view.tree.theme = theme(for: key.slot.kind)
        }
        for key in mounts.keys {
            place(key)
        }
        return change
    }

    func arrangeBars() {
        for bar in bars.surfaces.values {
            for (section, ids) in setup.resolution.bar {
                bar.setSection(
                    section,
                    ids
                        .compactMap {
                            mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), surface: SurfaceAddress.main, display: bar.display.id)]
                        },
                )
            }
        }
    }

    func placeInBar(_ key: MountKey) {
        guard let bar = bars[key.display] else { return }
        for (section, ids) in setup.resolution.bar where ids.contains(key.slot.id) {
            bar.setSection(
                section,
                ids.compactMap { mounts[MountKey(slot: SlotKey(id: $0, kind: .barWidget), surface: key.surface, display: key.display)] },
            )
        }
    }

    var panels: [NSPanel] {
        bars.surfaces.values.map(\.panel) + windows.values.map(\.panel)
    }

    var appearance: NSAppearance? {
        NSAppearance(theme.value.mode)
    }

    @discardableResult
    func commitFrame() -> Timings {
        var timings = Timings()
        for panel in panels where panel.isVisible {
            measure(.layout, &timings) { FrameLog.shared.record(.layout) { panel.contentView?.layoutSubtreeIfNeeded() } }
            measure(.display, &timings) { FrameLog.shared.record(.draw) { panel.displayIfNeeded() } }
        }
        measure(.flush, &timings) { FrameLog.shared.record(.commit) { CATransaction.flush() } }
        return timings
    }

    func theme(for kind: PluginKind) -> Theme {
        kind == .bar || kind == .barWidget ? theme.value.inBar : theme.value
    }

    func fade(_ slot: SlotKey) -> Double {
        slot.kind.isSurface ? theme.value.motion.fade : 0
    }

    func pointerDisplay() -> String? {
        let pointer = NSEvent.mouseLocation
        return displays.first { NSMouseInRect(pointer, $0.frame, false) }?.id
    }

    func open(_ window: SurfaceWindow, _ key: MountKey, focusable: Bool) {
        if key.slot.kind == .bar {
            watchTopEdge(of: window.card) { [weak self] in self?.pointerReachedTop(key.display) }
        }
        window.show(fade: fade(key.slot))
        TraceLog.note(
            "show",
            TraceLog.applying,
            ["plugin": TraceLog.slot(key.slot), "surface": .string(key.surface), "display": .string(key.display)],
        )
        if key.slot.kind.isSurface {
            let slotKey = key.slot
            window.panel.onScroll = { [weak self] event in self?.slots[slotKey]?.runtime?.scroll(event) }
        }
        if key.slot.kind.isSurface, focusable {
            focus(window, key)
        }
        watchClicks()
    }

    func keyPressed(_ key: String, _ mount: MountKey) {
        if tracing {
            log("key plugin=\(mount.slot) surface=\(mount.surface) key=\(key)")
        }
        slots[mount.slot]?.runtime?.key(key) { [weak self] in
            if mount.slot.kind.hides(onUnhandled: key) {
                self?.hide(mount, Trace("escape"))
            }
        }
    }

    func perform(_ event: ActionEvent, _ key: SlotKey) {
        if tracing {
            log("action plugin=\(key) action=\(event.name) payload=\(event.payload.text) origin=\(event.origin.map { "\($0)" } ?? "none")")
        }
        if event.gesture == .scroll {
            slots[key]?.runtime?.scroll(event.payload, action: event.name, origin: event.origin)
        } else {
            slots[key]?.runtime?.perform(event.name, event.payload, origin: event.origin)
        }
    }

    func clicked(at point: NSPoint) {
        let menus = windows.keys.filter { $0.slot.kind == .menu }
        for menu in menus where !windows.contains(where: { $0.key.slot == menu.slot && $0.key.surface == menu.surface && $0.value.contains(point) }) {
            hide(menu, Trace("click-outside"))
        }
    }
}
