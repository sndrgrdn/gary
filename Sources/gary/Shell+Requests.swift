import AppKit
import GaryCore

extension Shell {
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var response: Response?

        func set(_ value: Response) {
            lock.withLock {
                if response == nil {
                    response = value
                }
            }
            semaphore.signal()
        }

        func wait(_ timeout: TimeInterval) -> Response {
            _ = semaphore.wait(timeout: .now() + timeout)
            return lock.withLock { response ?? .failure("timed out") }
        }
    }

    func serve(_ line: String) -> String {
        let request: Request
        do {
            request = try Request.decode(line: line)
        } catch {
            return Response.failure("\(error)").line
        }
        let box = ReplyBox()
        DispatchQueue.main.async { self.handle(request, reply: box.set) }
        return box.wait(request.timeout).line
    }

    private func handle(_ request: Request, reply: @escaping (Response) -> Void) {
        let trace = Trace("ipc-\(request.verb)")
        switch request {
        case .ping:
            reply(.ok("pong"))
        case .quit:
            reply(.ok("quitting"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.quit() }
        case let .summon(id):
            summon(id, trace, reply)
        case let .hide(id):
            reply(hide(id, trace))
        case let .toggle(id):
            toggle(id, trace, reply)
        case let .reloadPlugins(id):
            reply(reloadPlugins(id, trace))
        case .rescanPlugins:
            _ = refresh(config: false, catalog: true, trace)
            reply(.ok("\(catalog.plugins.count) plugins, \(catalog.problems.count) problems"))
        case .reloadConfig:
            reply(refresh(config: true, catalog: false, trace))
        case let .applyTheme(payload):
            themePayload = payload
            reply(reloadTheme(trace))
        case .listPlugins:
            reply(.ok(listing()))
        case .doctor:
            reply(.ok(Doctor.report(doctorRuntime())))
        case .permissions:
            reply(.ok(permissionReport(enabled: enabledManifests)))
        case let .requestPermission(permission):
            reply(.ok(permission.request()))
        case let .action(id, kind, action, payload):
            reply(send(action, payload, to: SlotKey(id: id, kind: kind)))
        case let .call(id, method, arguments):
            call(id, method, arguments, trace) { response in
                guard case let .ok(text) = response, case let .string(string)? = try? JSON.parse(text) else { return reply(response) }
                reply(.ok(string))
            }
        }
    }

    private func reloadPlugins(_ id: PluginID?, _ trace: Trace) -> Response {
        let live = slots.values.filter { (id == nil || $0.key.id == id) && (isLive($0) || $0.disabledReason != nil) }
        if let id, live.isEmpty {
            return .failure("\(id) is not loaded")
        }
        for slot in live {
            reload(slot, trace)
        }
        return .ok("reloading \(live.count)")
    }

    private func send(_ action: String, _ payload: String?, to key: SlotKey) -> Response {
        guard let runtime = slots[key]?.runtime else { return .failure("\(key.id) has no running \(key.kind.rawValue)") }
        runtime.perform(action, payload.map { Double($0).map(JSON.number) ?? .string($0) } ?? .null)
        return .ok("sent \(action) to \(key)")
    }

    func call(_ id: PluginID, _ method: String, _ arguments: [String], _ trace: Trace, _ reply: @escaping (Response) -> Void) {
        guard let slot = handlerSlot(id) else { reply(.failure("\(id) is not enabled"))
            return
        }
        var answered = false
        let once: (Response) -> Void = { response in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                reply(response)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Request.callTimeout) {
            once(.failure("\(id) \(method) did not finish within \(Int(Request.callTimeout)) seconds"))
        }
        withRuntime(slot, trace) { runtime in
            guard let runtime else { return once(.failure("\(id) did not load")) }
            runtime.call(method, arguments, reply: once)
        }
    }

    func surfaceSlot(_ id: PluginID) -> PluginSlot? {
        catalog.plugins[id]?.manifest.kinds.lazy.filter(\.isSurface).compactMap { self.slots[SlotKey(id: id, kind: $0)] }.first
    }

    private func pointerDisplay() -> String? {
        let pointer = NSEvent.mouseLocation
        return displays.first { NSMouseInRect(pointer, $0.frame, false) }?.id
    }

    func toggle(_ id: PluginID, _ trace: Trace, _ reply: ((Response) -> Void)? = nil) {
        if surfaceSlot(id)?.visible == true {
            let response = hide(id, trace)
            reply?(response)
        } else {
            summon(id, trace, reply)
        }
    }

    func summon(_ id: PluginID, _ trace: Trace, _ reply: ((Response) -> Void)? = nil) {
        guard let slot = surfaceSlot(id) else { reply?(.failure("no enabled surface \(id)"))
            return
        }
        if let reason = slot.disabledReason {
            reply?(.failure("\(id) is disabled: \(reason)"))
            return
        }
        if slot.visible, slot.runtime != nil {
            reply?(.ok("shown"))
            return
        }
        slot.visible = true
        slot.focused = pointerDisplay()
        if let reply {
            slot.waiters.append(reply)
        }
        if let runtime = slot.runtime {
            runtime.setScene(scene(for: slot), trace)
        } else if slot.candidate == nil {
            load(slot, trace)
        }
    }

    func hide(_ id: PluginID, _ trace: Trace) -> Response {
        guard let slot = surfaceSlot(id) else { return .failure("no enabled surface \(id)") }
        guard slot.visible else { return .ok("hidden") }
        slot.visible = false
        if id == .onboarding {
            recordOnboardingDismissed()
        }
        if slot.bundle.manifest.keepLoaded, let runtime = slot.runtime {
            unmount(slot.key)
            runtime.setScene(scene(for: slot), trace)
        } else {
            stop(slot)
        }
        slot.answerWaiters(.ok("hidden"))
        return .ok("hidden")
    }

    private func doctorRuntime() -> DoctorRuntime {
        let states = slots.values.sorted { $0.key.description < $1.key.description }.map { slot -> (String, String?) in
            switch slot.phase {
            case let .failed(reason): (slot.key.description, "failed: \(reason)")
            case let .disabled(reason): (slot.key.description, "disabled after repeated failures: \(reason)")
            case .stopped, .running: (slot.key.description, nil)
            }
        }
        return DoctorRuntime(pid: getpid(), enabled: enabledManifests, pluginStates: states)
    }

    var enabledManifests: [PluginManifest] {
        resolution.enabled.compactMap { catalog.plugins[$0]?.manifest }
    }

    private func listing() -> String {
        var lines = catalog.sortedIDs.compactMap { catalog.plugins[$0] }.map { bundle -> String in
            let manifest = bundle.manifest
            let id = manifest.id
            let states = manifest.kinds.map { kind -> String in
                guard resolution.enabled.contains(id) else { return "\(kind.rawValue):disabled" }
                guard let slot = slots[SlotKey(id: id, kind: kind)]
                else { return "\(kind.rawValue):\(kind == .barWidget ? "not-in-bar" : "inactive")" }
                switch slot.phase {
                case .running: return "\(kind.rawValue):\(kind.isSurface ? (slot.visible ? "shown" : "paused") : "running")"
                case .stopped: return "\(kind.rawValue):\(kind.isSurface ? "hidden" : "stopped")"
                case let .failed(reason): return "\(kind.rawValue):failed(\(reason))"
                case let .disabled(reason): return "\(kind.rawValue):disabled(\(reason))"
                }
            }
            return [id.rawValue, manifest.version, bundle.origin == .builtin ? "builtin" : "user", states.joined(separator: " ")]
                .joined(separator: "\t")
        }
        lines += catalog.problems.map { "\($0.directory.lastPathComponent)\t-\tinvalid\t\($0.reason)" }
        return lines.joined(separator: "\n")
    }
}
