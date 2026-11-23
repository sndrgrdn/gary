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
        perform(slots.sync(wanted), trace)
        claimMediaKeys()
        arrangeBars()
        commitFrame()
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
        switch kind {
        case .barWidget: Scene(displays: displays.filter { bars[$0.id] != nil }, shown: [SurfaceAddress.main: ShownSurface()])
        case .bar: Scene(displays: displays, shown: [SurfaceAddress.main: ShownSurface()])
        case .service: Scene()
        case .panel, .overlay, .menu: Scene(displays: displays, shown: shown)
        }
    }

    func makeRuntime(_ key: SlotKey, _ bundle: PluginBundle, _ scene: Scene) -> PluginRuntime {
        let delivery = MainDelivery { [weak self] runtime, event in self?.handle(event, from: runtime, key) }
        return PluginRuntime(
            bundle: bundle, kind: key.kind, scene: scene,
            settings: config.settings[key.id] ?? .object([:]), theme: theme.json, hub: hub,
            deliver: { delivery.send($0, $1) }, engine: engines.engine(for: key.kind),
        )
    }

    func perform(_ effects: [PluginSlots<PluginRuntime>.Effect], _ trace: Trace) {
        for effect in effects {
            switch effect {
            case let .start(runtime): runtime.load(trace)
            case let .stop(runtime): runtime.stop()
            case let .setScene(runtime, scene): runtime.setScene(scene, trace)
            case let .present(key, output): present(key, output, trace)
            case let .unmount(key, surface): unmount(key, surface: surface)
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
        case let .output(output, trace):
            perform(slots.output(runtime, at: key, output), trace)
        case let .surface(request, address, origin):
            surfaceRequested(request, address, origin, by: key.id)
        case let .call(target, method, arguments, reply):
            call(target.plugin ?? key.id, target.kind, method, arguments, reply)
        case let .failed(reason):
            perform(slots.failed(runtime, at: key, reason), Trace("bar-fallback"))
            commitFrame()
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
}
