import AppKit
import GaryCore

extension Shell {
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
            measure(.layout, &timings) { panel.contentView?.layoutSubtreeIfNeeded() }
            measure(.display, &timings) { panel.displayIfNeeded() }
        }
        measure(.flush, &timings) { CATransaction.flush() }
        return timings
    }

    func refreshDisplays(_ trace: Trace) {
        let theme = theme.value
        let next = NSScreen.screens.enumerated().map { $1.display(index: $0, theme: theme) }
        let change = DisplayChange(from: displays, to: next)
        displays = next
        let appearance = appearance
        let level = SurfaceLevels.bar
        let barChange = bars.sync(usesBuiltinBar ? next : [], open: { [weak self] display in
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
        guard !change.isEmpty || !barChange.isEmpty else { return }
        for key in mounts.keys where change.removed.contains(key.display) || (key.slot.kind == .barWidget && bars[key.display] == nil) {
            unmount(key)
        }
        for slot in slots.values {
            slot.runtime?.setScene(scene(slot.key.kind, slot.shown), trace)
        }
        log("screens added=\(change.added.count) removed=\(change.removed.count) changed=\(change.changed.count) bars=\(bars.surfaces.count): "
            + displays
            .map {
                "\($0.id.prefix(8)) \(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY)) notch=\($0.notch != nil)"
            }.joined(separator: "; "))
    }
}
