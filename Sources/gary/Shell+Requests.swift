import AppKit
import GaryCore

extension Shell {
    private final nonisolated class ReplyBox: @unchecked Sendable {
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

    nonisolated func serve(_ line: String) -> String {
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
        case let .summon(address):
            summon(address, trace, reply)
        case let .hide(address):
            reply(hide(address, trace))
        case let .toggle(address):
            toggle(address, trace, reply)
        case let .reloadPlugins(id):
            reply(reloadPlugins(id, trace))
        case .rescanPlugins:
            _ = refresh(config: false, catalog: true, trace)
            reply(.ok("\(setup.catalog.plugins.count) plugins, \(setup.catalog.problems.count) problems"))
        case .reloadConfig:
            reply(refresh(config: true, catalog: false, trace))
        case let .applyTheme(payload):
            reply(changeTheme(trace) { try theme.apply(payload) })
        case .listPlugins:
            reply(.ok(listing()))
        case .doctor:
            reply(.ok(Doctor.report(doctorRuntime(), system: theme.system)))
        case .permissions:
            reply(.ok(permissionReport(enabled: setup.enabledManifests)))
        case let .requestPermission(permission):
            reply(.ok(permission.request()))
        case let .call(id, method, arguments):
            call(id, nil, method, arguments) { response in
                guard case let .ok(text) = response, case let .string(string)? = try? JSON.parse(text) else { return reply(response) }
                reply(.ok(string))
            }
        case .action, .key, .scroll, .hover, .click, .tree, .capture:
            drive(request, reply)
        }
    }

    private func reloadPlugins(_ id: PluginID?, _ trace: Trace) -> Response {
        let live = slots.values.filter { (id == nil || $0.key.id == id) && ($0.isLive || $0.disabledReason != nil) }.map(\.key)
        if let id, live.isEmpty {
            return .failure("\(id) is not loaded")
        }
        for key in live {
            perform(slots.reload(key), trace)
        }
        return .ok("reloading \(live.count)")
    }

    func call(_ id: PluginID, _ kind: PluginKind?, _ method: String, _ arguments: [String], _ reply: @escaping (Response) -> Void) {
        guard let key = kind.map({ SlotKey(id: id, kind: $0) }) ?? slots.handler(of: id), slots[key] != nil else {
            reply(.failure("\(kind.map { SlotKey(id: id, kind: $0).description } ?? id.rawValue) is not enabled"))
            return
        }
        var answered = false
        let once: @MainActor @Sendable (Response) -> Void = { response in
            guard !answered else { return }
            answered = true
            reply(response)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Request.callTimeout) {
            once(.failure("\(id) \(method) did not finish within \(Int(Request.callTimeout)) seconds"))
        }
        perform(slots.use(key) { runtime in
            guard let runtime else { return once(.failure("\(id) did not load")) }
            runtime.call(method, arguments) { response in DispatchQueue.main.async { once(response) } }
        }, Trace("call"))
    }

    func toggle(_ address: SurfaceAddress, _ trace: Trace, origin: CGRect? = nil, _ reply: ((Response) -> Void)? = nil) {
        if slots.surfaceSlot(address)?.shown[address.surface] != nil {
            let response = hide(address, trace)
            reply?(response)
        } else {
            summon(address, trace, origin: origin, reply)
        }
    }

    func summon(_ address: SurfaceAddress, _ trace: Trace, origin: CGRect? = nil, _ reply: ((Response) -> Void)? = nil) {
        guard let slot = slots.surfaceSlot(address) else {
            reply?(.failure(slots.missingSurface(address)))
            return
        }
        perform(slots.show(address.surface, in: slot.key, ShownSurface(focused: screens.pointerDisplay(), origin: origin), reply), trace)
    }

    func hide(_ address: SurfaceAddress, _ trace: Trace) -> Response {
        guard let slot = slots.surfaceSlot(address) else { return .failure(slots.missingSurface(address)) }
        return hide(address.surface, in: slot.key, trace)
    }

    func hide(_ surface: String, in key: SlotKey, _ trace: Trace) -> Response {
        guard slots[key]?.shown[surface] != nil else { return .ok("hidden") }
        if key.id == .onboarding {
            recordOnboardingDismissed()
        }
        perform(slots.hide(surface, in: key), trace)
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
        return DoctorRuntime(pid: getpid(), enabled: setup.enabledManifests, pluginStates: states, themePayload: theme.payload)
    }

    private func listing() -> String {
        let catalog = setup.catalog
        var lines = catalog.sortedIDs.compactMap { catalog.plugins[$0] }.map { bundle -> String in
            let manifest = bundle.manifest
            let id = manifest.id
            let states = manifest.kinds.map { kind -> String in
                guard setup.resolution.enabled.contains(id) else { return "\(kind.rawValue):disabled" }
                guard let slot = slots[SlotKey(id: id, kind: kind)]
                else { return "\(kind.rawValue):\(kind == .barWidget ? "not-in-bar" : "inactive")" }
                switch slot.phase {
                case .running where (slot.bundle.manifest.surfaces[kind]?.count ?? 0) > 1:
                    return "\(kind.rawValue):" + (slot.bundle.manifest.surfaces[kind] ?? [])
                        .map { "\($0)=\(slot.shown[$0] != nil ? "shown" : "hidden")" }
                        .joined(separator: ",")
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
