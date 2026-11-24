import AppKit
import GaryCore

extension Shell {
    func hotkeyPressed(_ binding: HotkeyBinding) {
        let trace = Trace("hotkey")
        if tracing {
            log("hotkey \(binding.hotkey.keys) plugin=\(binding.owner) id=\(binding.hotkey.id)")
        }
        guard !HotkeyListeners.shared.press(binding), let key = slots.handler(of: binding.owner) else { return }
        perform(slots.use(key) { runtime in runtime?.hotkey(binding.hotkey.id) }, trace)
    }

    func mediaKeyPressed(_ event: JSON, _ keys: [SlotKey]) {
        let trace = Trace("mediakey")
        for key in keys {
            perform(slots.use(key) { runtime in runtime?.mediaKey(event) }, trace)
        }
    }

    var usesBuiltinBar: Bool {
        guard let id = setup.resolution.barPlugin else { return true }
        switch slots[SlotKey(id: id, kind: .bar)]?.phase {
        case .failed, .disabled: return true
        default: return false
        }
    }

    func refreshDisplays(_ trace: Trace) {
        if let change = screens.refresh(builtinBar: usesBuiltinBar) {
            displaysChanged(change, trace)
        }
    }

    func displaysChanged(_ change: DisplayChange, _ trace: Trace) {
        for slot in slots.values {
            slot.runtime?.setScene(scene(slot.key.kind, slot.shown), trace)
        }
        log(
            "screens added=\(change.added.count) removed=\(change.removed.count) changed=\(change.changed.count) bars=\(screens.bars.surfaces.count): "
                + screens.displays
                .map {
                    "\($0.id.prefix(8)) \(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY)) notch=\($0.notch != nil)"
                }.joined(separator: "; "),
        )
    }

    func sync(_ trace: Trace, reloading: Set<SlotKey> = []) {
        refreshDisplays(trace)
        perform(slots.sync(setup.wanted(builtinBar: usesBuiltinBar), reloading: reloading), trace)
        claimMediaKeys()
        screens.arrangeBars()
        screens.commitFrame()
    }

    private func claimMediaKeys() {
        var claims: [MediaKey: [SlotKey]] = [:]
        for slot in slots.values {
            for mediaKey in slot.bundle.manifest.mediaKeys[slot.key.kind] ?? [] {
                claims[mediaKey, default: []].append(slot.key)
            }
        }
        mediaKeys?.claim(claims)
    }

    func scene(_ kind: PluginKind, _ shown: [String: ShownSurface]) -> Scene {
        let displays = screens.displays
        return switch kind {
        case .barWidget: Scene(displays: displays.filter { screens.bars[$0.id] != nil }, shown: [SurfaceAddress.main: ShownSurface()])
        case .bar: Scene(displays: displays, shown: [SurfaceAddress.main: ShownSurface()])
        case .service: Scene()
        case .panel, .overlay, .menu: Scene(displays: displays, shown: shown)
        }
    }

    func makeRuntime(_ key: SlotKey, _ bundle: PluginBundle, _ scene: Scene) -> PluginRuntime {
        let delivery = MainDelivery { [weak self] runtime, event in self?.handle(event, from: runtime, key) }
        let runtime = PluginRuntime(
            bundle: bundle, kind: key.kind, scene: scene,
            settings: setup.config.settings[key.id] ?? .object([:]), theme: theme.value.json, hub: hub,
            deliver: { delivery.send($0, $1) }, engine: engines.engine(for: key),
        )
        runtime.metrics.whenBusy { [weak runtime] in runtime.map { delivery.send($0, .busy) } }
        return runtime
    }

    func perform(_ effects: [PluginSlots<PluginRuntime>.Effect], _ trace: Trace) {
        let outer = TraceLog.applying
        TraceLog.applying = trace.id
        defer { TraceLog.applying = outer }
        for effect in effects {
            switch effect {
            case let .start(runtime): runtime.load(trace)
            case let .stop(runtime): runtime.stop(trace)
            case let .setScene(runtime, scene): runtime.setScene(scene, trace)
            case let .present(key, output): present(key, output, trace)
            case let .unmount(key, surface): screens.unmount(key, surface: surface)
            case let .answer(waiters, response): waiters.forEach { $0(response) }
            case let .later(delay, cause, transition):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.perform(transition(), Trace(cause)) }
            case .sync: sync(trace)
            }
        }
    }

    private func handle(_ event: RuntimeEvent, from runtime: PluginRuntime, _ key: SlotKey) {
        guard slots.isCurrent(runtime, at: key) else {
            runtime.stop()
            return
        }
        switch event {
        case let .loaded(output, trace):
            perform(slots.loaded(runtime, at: key, output), trace)
            claimMediaKeys()
        case let .output(output, trace):
            perform(slots.output(runtime, at: key, output), trace)
        case let .surface(request, address, origin):
            surfaceRequested(request, address, origin, by: key.id)
        case let .call(target, method, arguments, reply):
            call(target.plugin ?? key.id, target.kind, method, arguments, reply)
        case let .failed(reason):
            perform(slots.failed(runtime, at: key, reason), Trace("bar-fallback"))
            screens.commitFrame()
        case .busy:
            guard engines.promote(key) else { return }
            log("plugin \(key): spent over \(PluginMetrics.busyCPU) of CPU in a minute, so it reloads on its own engine")
            perform(slots.reload(key), Trace("busy"))
        }
    }

    private func surfaceRequested(_ request: SurfaceRequest, _ address: SurfaceAddress, _ origin: CGRect?, by id: PluginID) {
        let trace = Trace("host-\(request.rawValue)")
        let report: (Response) -> Void = { response in
            if case let .failure(reason) = response {
                log("plugin \(id): host.\(request.rawValue)(\"\(address)\"): \(reason)")
            }
        }
        switch request {
        case .show: summon(address, trace, origin: origin, report)
        case .hide: report(hide(address, trace))
        case .toggle: toggle(address, trace, origin: origin, report)
        }
    }

    private func present(_ slot: SlotKey, _ output: RuntimeOutput, _ trace: Trace) {
        var timings = trace.timings
        let started = TraceLog.isOn ? TraceLog.uptime() : 0
        let changes = measure(.apply, &timings) { FrameLog.shared.record(.tree(slot.description)) { screens.present(slot, output) } }
        timings.merge(screens.commitFrame())
        TraceLog.note("apply", trace.id, [
            "plugin": TraceLog.slot(slot),
            "changed": .number(Double(changes.values.count { $0 })),
            "ms": TraceLog.milliseconds(since: started),
        ])
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
                output.trees[key.surface]?[key.display]??.summary ?? "",
            ))
        }
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
