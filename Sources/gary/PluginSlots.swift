import Foundation
import GaryCore

struct SlotKey: Hashable, CustomStringConvertible {
    let id: PluginID
    let kind: PluginKind
    var description: String {
        "\(id)/\(kind.rawValue)"
    }
}

protocol SlotRuntime: AnyObject {
    var bundle: PluginBundle { get }
    var initialScene: Scene { get }
}

struct PluginSlot<Runtime: SlotRuntime> {
    enum Phase {
        case stopped
        case running(Runtime)
        case failed(String)
        case disabled(String)
    }

    let key: SlotKey
    var wanted: PluginBundle
    var phase = Phase.stopped
    var failures = RestartBudget(limit: 5, window: 60)
    var candidate: Runtime?
    var shown: [String: ShownSurface] = [:]
    var surfaces: [String: SurfaceSpec] = [:]
    var waiters: [(Response) -> Void] = []
    var lastUse: Double?

    var visible: Bool {
        !shown.isEmpty
    }

    var bundle: PluginBundle {
        runtime?.bundle ?? wanted
    }

    var isLive: Bool {
        !key.kind.isSurface || visible || runtime != nil
    }

    var runtime: Runtime? {
        if case let .running(runtime) = phase {
            return runtime
        }
        return nil
    }

    var disabledReason: String? {
        if case let .disabled(reason) = phase {
            return reason
        }
        return nil
    }

    mutating func takeWaiters() -> [(Response) -> Void] {
        defer { waiters = [] }
        return waiters
    }
}

final class PluginSlots<Runtime: SlotRuntime> {
    typealias Waiter = (Response) -> Void

    enum Effect {
        case start(Runtime)
        case stop(Runtime)
        case setScene(Runtime, Scene)
        case present(SlotKey, RuntimeOutput)
        case unmount(SlotKey, surface: String?)
        case answer([Waiter], Response)
        case later(TimeInterval, cause: String, () -> [Effect])
        case sync
    }

    private var slots: [SlotKey: PluginSlot<Runtime>] = [:]
    private let make: (SlotKey, PluginBundle, Scene) -> Runtime
    private let scene: (PluginKind, [String: ShownSurface]) -> Scene
    private let clock: () -> Double

    init(
        make: @escaping (SlotKey, PluginBundle, Scene) -> Runtime,
        scene: @escaping (PluginKind, [String: ShownSurface]) -> Scene,
        clock: @escaping () -> Double = now,
    ) {
        self.make = make
        self.scene = scene
        self.clock = clock
    }

    subscript(key: SlotKey) -> PluginSlot<Runtime>? {
        slots[key]
    }

    var values: Dictionary<SlotKey, PluginSlot<Runtime>>.Values {
        slots.values
    }

    private func scene(of slot: PluginSlot<Runtime>) -> Scene {
        scene(slot.key.kind, slot.shown)
    }

    func handler(of id: PluginID) -> SlotKey? {
        PluginKind.handlerOrder.lazy.map { SlotKey(id: id, kind: $0) }.first { self.slots[$0] != nil }
    }

    func surfaces(of id: PluginID) -> [PluginSlot<Runtime>] {
        PluginKind.allCases.filter(\.isSurface).compactMap { slots[SlotKey(id: id, kind: $0)] }
    }

    func surfaceSlot(_ address: SurfaceAddress) -> PluginSlot<Runtime>? {
        surfaces(of: address.plugin).first { $0.bundle.manifest.surfaceKind(address.surface) == $0.key.kind }
    }

    func isCurrent(_ runtime: Runtime, at key: SlotKey) -> Bool {
        slots[key].map { $0.candidate === runtime || $0.runtime === runtime } ?? false
    }

    func sync(_ wanted: [SlotKey: PluginBundle], reloading: Set<SlotKey> = []) -> [Effect] {
        var effects: [Effect] = []
        for key in slots.keys where wanted[key] == nil {
            effects += update(key) { stop(&$0) }
            slots[key] = nil
        }
        for (key, bundle) in wanted {
            if let slot = slots[key] {
                guard slot.wanted != bundle || reloading.contains(key) else { continue }
                effects += update(key) { slot in
                    slot.wanted = bundle
                    return reload(&slot)
                }
            } else {
                slots[key] = PluginSlot(key: key, wanted: bundle)
                if !key.kind.isSurface {
                    effects += update(key) { load(&$0) }
                }
            }
        }
        return effects
    }

    func reload(_ key: SlotKey) -> [Effect] {
        update(key) { reload(&$0) }
    }

    func use(_ key: SlotKey, _ body: @escaping (Runtime?) -> Void) -> [Effect] {
        let waiter: Waiter = { [weak self] _ in body(self?.slots[key]?.runtime) }
        return update(key) { slot in
            var effects: [Effect]
            if slot.runtime != nil || slot.disabledReason != nil {
                effects = [.answer([waiter], .ok("running"))]
            } else {
                slot.waiters.append(waiter)
                effects = slot.candidate == nil ? load(&slot) : []
            }
            if key.kind.isSurface, !slot.bundle.manifest.keepLoaded {
                slot.lastUse = clock()
                effects.append(stopWhenIdle(key, after: Request.callTimeout))
            }
            return effects
        }
    }

    func show(_ surface: String, in key: SlotKey, _ shown: ShownSurface, _ reply: Waiter?) -> [Effect] {
        update(key) { slot in
            if let reason = slot.disabledReason {
                return [.answer(reply.map { [$0] } ?? [], .failure("\(key.id) is disabled: \(reason)"))]
            }
            if slot.shown[surface] != nil, slot.runtime != nil {
                return [.answer(reply.map { [$0] } ?? [], .ok("shown"))]
            }
            slot.shown[surface] = shown
            if let reply {
                slot.waiters.append(reply)
            }
            if let runtime = slot.runtime {
                return [.setScene(runtime, scene(of: slot))]
            }
            return slot.candidate == nil ? load(&slot) : []
        }
    }

    func hide(_ surface: String, in key: SlotKey) -> [Effect] {
        update(key) { slot in
            guard slot.shown.removeValue(forKey: surface) != nil else { return [] }
            var effects: [Effect] = if slot.visible || slot.bundle.manifest.keepLoaded {
                [.unmount(key, surface: surface)] + (slot.runtime.map { [.setScene($0, scene(of: slot))] } ?? [])
            } else {
                stop(&slot)
            }
            if !slot.visible {
                effects.append(.answer(slot.takeWaiters(), .ok("hidden")))
            }
            return effects
        }
    }

    func loaded(_ runtime: Runtime, at key: SlotKey, _ output: RuntimeOutput) -> [Effect] {
        update(key) { slot in
            guard slot.candidate === runtime else { return [] }
            slot.candidate = nil
            var effects = slot.runtime.map { [Effect.stop($0)] } ?? []
            slot.phase = .running(runtime)
            log("plugin \(key): loaded \(slot.bundle.manifest.version)")
            effects += present(&slot, output)
            let scene = scene(of: slot)
            if runtime.initialScene != scene {
                effects.append(.setScene(runtime, scene))
            }
            effects.append(.answer(slot.takeWaiters(), .ok(slot.visible ? "shown" : "loaded")))
            if key.kind == .bar {
                effects.append(.sync)
            }
            return effects
        }
    }

    func output(_ runtime: Runtime, at key: SlotKey, _ output: RuntimeOutput) -> [Effect] {
        update(key) { slot in
            guard slot.runtime === runtime else { return [] }
            var effects = present(&slot, output)
            if slot.visible {
                effects.append(.answer(slot.takeWaiters(), .ok("shown")))
            }
            return effects
        }
    }

    func failed(_ runtime: Runtime, at key: SlotKey, _ reason: String) -> [Effect] {
        update(key) { slot in
            if slot.candidate === runtime {
                slot.candidate = nil
                if slot.runtime != nil {
                    log("plugin \(key): reload rejected, the running version stays: \(reason)")
                    return []
                }
            }
            slot.phase = .failed(reason)
            slot.shown = [:]
            var effects: [Effect] = [.unmount(key, surface: nil), .answer(slot.takeWaiters(), .failure("\(key.id) failed: \(reason)"))]
            log("plugin \(key): failed: \(reason)")
            if !slot.failures.allowsRestart(afterFailureAt: clock()) {
                slot.phase = .disabled("\(slot.failures.summary), last: \(reason)")
                log("plugin \(key): disabled after \(slot.failures.summary); reload it or change its files to try again")
            } else if !key.kind.isSurface {
                effects.append(.later(1, cause: "restart") { [weak self] in self?.restart(key) ?? [] })
            }
            if key.kind == .bar {
                effects.append(.sync)
            }
            return effects
        }
    }

    private func update(_ key: SlotKey, _ transition: (inout PluginSlot<Runtime>) -> [Effect]) -> [Effect] {
        guard var slot = slots[key] else { return [] }
        let effects = transition(&slot)
        slots[key] = slot
        return effects
    }

    private func stopWhenIdle(_ key: SlotKey, after delay: TimeInterval) -> Effect {
        .later(delay, cause: "idle") { [weak self] in
            guard let self else { return [] }
            return update(key) { slot in
                guard !slot.visible, !slot.bundle.manifest.keepLoaded, slot.runtime != nil || slot.candidate != nil,
                      let lastUse = slot.lastUse else { return [] }
                let idle = clock() - lastUse
                return idle < Request.callTimeout ? [stopWhenIdle(key, after: Request.callTimeout - idle)] : stop(&slot)
            }
        }
    }

    private func reload(_ slot: inout PluginSlot<Runtime>) -> [Effect] {
        slot.failures.reset()
        if slot.disabledReason != nil {
            slot.phase = .stopped
        }
        return slot.isLive ? load(&slot) : []
    }

    private func restart(_ key: SlotKey) -> [Effect] {
        update(key) { slot in
            guard case .failed = slot.phase, slot.candidate == nil else { return [] }
            log("plugin \(key): restarting (\(slot.failures.summary))")
            return load(&slot)
        }
    }

    private func load(_ slot: inout PluginSlot<Runtime>) -> [Effect] {
        let effects = slot.candidate.map { [Effect.stop($0)] } ?? []
        let runtime = make(slot.key, slot.wanted, scene(of: slot))
        slot.candidate = runtime
        return effects + [.start(runtime)]
    }

    private func stop(_ slot: inout PluginSlot<Runtime>) -> [Effect] {
        var effects = [slot.candidate, slot.runtime].compactMap { $0.map(Effect.stop) }
        slot.candidate = nil
        slot.phase = .stopped
        effects.append(.unmount(slot.key, surface: nil))
        effects.append(.answer(slot.takeWaiters(), .failure("\(slot.key.id) was stopped")))
        return effects
    }

    private func present(_ slot: inout PluginSlot<Runtime>, _ output: RuntimeOutput) -> [Effect] {
        guard !slot.key.kind.isSurface || slot.visible else { return [] }
        slot.surfaces = output.surfaces
        return [.present(slot.key, output)]
    }
}
