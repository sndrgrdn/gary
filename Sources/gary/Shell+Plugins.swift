import AppKit
import GaryCore

extension Shell {
    func hotkeyPressed(_ binding: HotkeyBinding) {
        let trace = Trace("hotkey")
        if tracing {
            log("hotkey \(binding.hotkey.keys) plugin=\(binding.owner) id=\(binding.hotkey.id)")
        }
        guard let slot = handlerSlot(binding.owner) else { return }
        withRuntime(slot, trace) { runtime in runtime?.hotkey(binding.hotkey.id) }
    }

    func handlerSlot(_ id: PluginID) -> PluginSlot? {
        let order: [PluginKind] = [.service, .panel, .overlay, .menu, .bar, .barWidget]
        return order.lazy.compactMap { self.slots[SlotKey(id: id, kind: $0)] }.first
    }

    func withRuntime(_ slot: PluginSlot, _ trace: Trace, _ body: @escaping (PluginRuntime?) -> Void) {
        if let runtime = slot.runtime {
            body(runtime)
            return
        }
        if slot.disabledReason != nil {
            body(nil)
            return
        }
        slot.waiters.append { [weak slot] _ in body(slot?.runtime) }
        if slot.candidate == nil {
            load(slot, trace)
        }
    }

    var usesBuiltinBar: Bool {
        guard let id = resolution.barPlugin else { return true }
        switch slots[SlotKey(id: id, kind: .bar)]?.phase {
        case .failed, .disabled: return true
        default: return false
        }
    }

    func sync(_ trace: Trace) {
        refreshDisplays(trace)
        var wanted: [SlotKey: PluginBundle] = [:]
        if usesBuiltinBar {
            for id in resolution.bar.values.joined() {
                wanted[SlotKey(id: id, kind: .barWidget)] = catalog.plugins[id]
            }
        }
        if let id = resolution.barPlugin {
            wanted[SlotKey(id: id, kind: .bar)] = catalog.plugins[id]
        }
        for bundle in resolution.enabled.compactMap({ catalog.plugins[$0] }) {
            for kind in bundle.manifest.kinds where kind.isSurface || kind == .service {
                wanted[SlotKey(id: bundle.manifest.id, kind: kind)] = bundle
            }
        }
        for (key, slot) in slots where wanted[key] == nil {
            stop(slot)
            slots[key] = nil
        }
        for (key, bundle) in wanted {
            if let slot = slots[key] {
                guard slot.bundle != bundle else { continue }
                slot.bundle = bundle
                reload(slot, trace)
            } else {
                let slot = PluginSlot(key: key, bundle: bundle)
                slots[key] = slot
                if !key.kind.isSurface {
                    load(slot, trace)
                }
            }
        }
        arrangeBars()
        commitFrame()
    }

    func reload(_ slot: PluginSlot, _ trace: Trace) {
        slot.failures.reset()
        if slot.disabledReason != nil {
            slot.phase = .stopped
        }
        if isLive(slot) {
            load(slot, trace)
        }
    }

    func isLive(_ slot: PluginSlot) -> Bool {
        !slot.key.kind.isSurface || slot.visible || slot.runtime != nil
    }

    func scene(for slot: PluginSlot) -> Scene {
        switch slot.key.kind {
        case .barWidget: Scene(displays: displays.filter { bars[$0.id] != nil }, shown: true)
        case .bar: Scene(displays: displays, shown: true)
        case .service: Scene()
        case .panel, .overlay, .menu: Scene(displays: displays, shown: slot.visible, focused: slot.focused)
        }
    }

    func load(_ slot: PluginSlot, _ trace: Trace) {
        slot.candidate?.stop()
        let key = slot.key
        let runtime = PluginRuntime(
            bundle: slot.bundle, kind: key.kind, scene: scene(for: slot),
            settings: config.settings[key.id] ?? .object([:]), theme: theme.json, hub: hub,
        ) { [weak self] runtime, event in
            DispatchQueue.main.async { self?.handle(event, from: runtime, key) }
        }
        slot.candidate = runtime
        runtime.load(trace)
    }

    func stop(_ slot: PluginSlot) {
        slot.candidate?.stop()
        slot.candidate = nil
        slot.runtime?.stop()
        slot.phase = .stopped
        unmount(slot.key)
        slot.answerWaiters(.failure("\(slot.key.id) was stopped"))
    }

    private func handle(_ event: RuntimeEvent, from runtime: PluginRuntime, _ key: SlotKey) {
        guard let slot = slots[key], slot.candidate === runtime || slot.runtime === runtime else {
            runtime.stop()
            return
        }
        switch event {
        case let .loaded(output, trace):
            loaded(slot, runtime, output, trace)
        case let .output(output, trace):
            guard slot.runtime === runtime else { return }
            present(slot, output, trace)
            if slot.visible {
                slot.answerWaiters(.ok("shown"))
            }
        case let .surface(request):
            surfaceRequested(request, by: key.id)
        case let .call(method, arguments, reply):
            call(key.id, method, arguments, Trace("host-call"), reply)
        case let .failed(reason):
            failed(slot, runtime, reason)
        }
    }

    private func loaded(_ slot: PluginSlot, _ runtime: PluginRuntime, _ output: RuntimeOutput, _ trace: Trace) {
        slot.candidate = nil
        slot.runtime?.stop()
        slot.phase = .running(runtime)
        log("plugin \(slot.key): loaded \(slot.bundle.manifest.version)")
        present(slot, output, trace)
        if runtime.initialScene != scene(for: slot) {
            runtime.setScene(scene(for: slot), trace)
        }
        slot.answerWaiters(.ok(slot.visible ? "shown" : "loaded"))
        if slot.key.kind == .bar {
            sync(trace)
        }
    }

    private func surfaceRequested(_ request: SurfaceRequest, by id: PluginID) {
        let trace = Trace("host-\(request.rawValue)")
        switch request {
        case .show: summon(id, trace)
        case .hide: _ = hide(id, trace)
        case .toggle: toggle(id, trace)
        }
    }

    private func failed(_ slot: PluginSlot, _ runtime: PluginRuntime, _ reason: String) {
        let key = slot.key
        if slot.candidate === runtime {
            slot.candidate = nil
            if slot.runtime != nil {
                log("plugin \(key): reload rejected, the running version stays: \(reason)")
                return
            }
        }
        slot.phase = .failed(reason)
        unmount(key)
        slot.visible = false
        slot.answerWaiters(.failure("\(key.id) failed: \(reason)"))
        log("plugin \(key): failed: \(reason)")
        if !slot.failures.allowsRestart(afterFailureAt: now()) {
            slot.phase = .disabled("\(slot.failures.summary), last: \(reason)")
            log("plugin \(key): disabled after \(slot.failures.summary); reload it or change its files to try again")
        } else if !key.kind.isSurface {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak slot] in
                guard let self, let slot, slots[key] === slot, case .failed = slot.phase, slot.candidate == nil else { return }
                log("plugin \(key): restarting (\(slot.failures.summary))")
                load(slot, Trace("restart"))
            }
        }
        if key.kind == .bar {
            sync(Trace("bar-fallback"))
        }
        commitFrame()
    }

    func perform(_ action: String, _ payload: JSON, _ key: SlotKey) {
        if tracing {
            log("action plugin=\(key) action=\(action) payload=\(payload.text)")
        }
        slots[key]?.runtime?.perform(action, payload)
    }
}
