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
        case let .call(id, method, arguments):
            call(id, nil, method, arguments) { response in
                guard case let .ok(text) = response, case let .string(string)? = try? JSON.parse(text) else { return reply(response) }
                reply(.ok(string))
            }
        case .action, .key, .scroll, .hover, .click, .tree, .capture:
            drive(request, reply)
        }
    }

    private func drive(_ request: Request, _ reply: @escaping (Response) -> Void) {
        switch request {
        case let .action(id, kind, action, payload):
            reply(click(action, payload, on: SlotKey(id: id, kind: kind)))
        case let .key(id, kind, keys):
            reply(press(keys, on: id, kind))
        case let .scroll(id, kind, over, distance):
            reply(scroll(distance, over: over, on: SlotKey(id: id, kind: kind)))
        case let .hover(id, kind, action, entering):
            reply(hover(action, entering: entering, on: SlotKey(id: id, kind: kind)))
        case let .click(id, kind, point):
            reply(click(at: point, on: SlotKey(id: id, kind: kind)))
        case let .tree(id, kind):
            outline(SlotKey(id: id, kind: kind), reply)
        case let .capture(id, kind, path):
            reply(capture(SlotKey(id: id, kind: kind), to: path))
        default:
            reply(.failure("\(request.verb) does not drive a surface"))
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

    private func click(_ action: String, _ payload: String?, on key: SlotKey) -> Response {
        guard let runtime = slots[key]?.runtime else { return .failure("\(key.id) has no running \(key.kind.rawValue)") }
        let value = payload.map { Double($0).map(JSON.number) ?? .string($0) } ?? .null
        guard let (view, gesture) = mounted(key).lazy.compactMap({ $0.clickable(action) }).first else {
            runtime.perform(action, value)
            return .ok("sent \(action) to \(key), where no shown node has it as its action")
        }
        view.send(gesture, value)
        return .ok("clicked \(action) on \(key) at \(view.screenFrame.map(describe) ?? "no frame")")
    }

    private func press(_ keys: [String], on id: PluginID, _ kind: PluginKind?) -> Response {
        let hotkey = { (key: String) in KeyCombo.parse(key).flatMap { self.hotkeys?.registered(by: id, as: $0) } }
        if let unknown = keys.first(where: { hotkey($0) == nil && NSEvent.keyDown(named: $0, windowNumber: 0) == nil }) {
            return .failure("\"\(unknown)\" is neither a key name that onKey gets nor a hotkey of \(id)")
        }
        for key in keys {
            if let binding = hotkey(key) {
                hotkeyPressed(binding)
                continue
            }
            let focused = windows.first { $0.key.slot.id == id && (kind == nil || $0.key.slot.kind == kind) && $0.value.panel.isKeyWindow }
            guard let panel = focused?.value.panel, let event = NSEvent.keyDown(named: key, windowNumber: panel.windowNumber) else {
                return .failure("\(kind.map { "\(id)/\($0.rawValue)" } ?? id.rawValue) has no focused surface to take \"\(key)\"")
            }
            NSApp.sendEvent(event)
        }
        return .ok("pressed \(keys.joined(separator: " "))")
    }

    private func scroll(_ distance: ScrollDistance, over action: String?, on key: SlotKey) -> Response {
        guard let runtime = slots[key]?.runtime else { return .failure("\(key.id) has no running \(key.kind.rawValue)") }
        let events: [JSON] = switch distance {
        case let .lines(y): [.scroll(x: 0, y: y, precise: false, phase: "none")]
        case let .points(y): [.scroll(x: 0, y: y, precise: true, phase: "began"), .scroll(x: 0, y: 0, precise: true, phase: "ended")]
        }
        if let action {
            guard let node = mounted(key).lazy.compactMap({ $0.node(withAction: action) }).first else {
                return .failure("no shown node of \(key) has the action \(action)")
            }
            if let target = node.scrollTarget {
                for event in events {
                    target.send(.scroll, event)
                }
                return .ok("scrolled \(target.actions[.scroll] ?? action) on \(key) at \(target.screenFrame.map(describe) ?? "no frame")")
            }
        }
        guard key.kind.isSurface else { return .failure("\(key) takes a scroll only over a node with scrollAction") }
        guard mounts.keys.contains(where: { $0.slot == key }) else { return .failure("\(key) is not shown") }
        for event in events {
            runtime.scroll(event)
        }
        return .ok("scrolled \(key)")
    }

    private func hover(_ action: String, entering: Bool, on key: SlotKey) -> Response {
        let views = mounted(key).flatMap { $0.descendants(GestureView.self) }
        guard let view = views.first(where: { $0.actions[.hover] == action }) else {
            return .failure("no shown node of \(key) has the hoverAction \(action)")
        }
        view.send(.hover, .bool(entering))
        return .ok("\(entering ? "entered" : "left") \(action) on \(key) at \(view.screenFrame.map(describe) ?? "no frame")")
    }

    private func click(at point: CGPoint, on key: SlotKey) -> Response {
        guard let host = mounted(key).first, let window = host.window else { return .failure("\(key) is not shown") }
        guard host.bounds.contains(point) else {
            return .failure(
                "\(key) is \(Int(host.bounds.width)) by \(Int(host.bounds.height)) points, so \(Int(point.x)),\(Int(point.y)) is outside it",
            )
        }
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0,
            )
            event.map(NSApp.sendEvent)
        }
        return .ok("clicked \(key) at \(describe(window.convertToScreen(CGRect(origin: location, size: .zero))))")
    }

    private func outline(_ key: SlotKey, _ reply: @escaping (Response) -> Void) {
        guard let tree = mounted(key).first?.tree else {
            reply(.failure("\(key) is not shown"))
            return
        }
        let recorder = FrameRecorder()
        tree.inspection = recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tree.inspection = nil
            reply(.ok(tree.root.outline(recorder.entries).joined(separator: "\n")))
        }
    }

    private func capture(_ key: SlotKey, to path: String) -> Response {
        guard let host = mounted(key).first else { return .failure("\(key) is not shown") }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return .failure("\(key) has nothing to draw") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return .failure("could not encode \(key) as PNG") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            return .failure("could not write \(path): \(error.localizedDescription)")
        }
        return .ok("wrote \(path), \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) pixels for \(Int(host.bounds.width))x\(Int(host.bounds.height)) points")
    }

    private func mounted(_ key: SlotKey) -> [TreeHostingView] {
        let pointer = pointerDisplay()
        return mounts.filter { $0.key.slot == key && !$0.value.isHidden }.sorted { $0.key.display == pointer && $1.key.display != pointer }
            .map(\.value)
    }

    private func describe(_ frame: CGRect) -> String {
        let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
        return String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, top, frame.width, frame.height)
    }

    func call(_ id: PluginID, _ kind: PluginKind?, _ method: String, _ arguments: [String], _ reply: @escaping (Response) -> Void) {
        guard let slot = kind.map({ slots[SlotKey(id: id, kind: $0)] }) ?? handlerSlot(id) else {
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
        withRuntime(slot, Trace("call")) { runtime in
            guard let runtime else { return once(.failure("\(id) did not load")) }
            runtime.call(method, arguments) { response in DispatchQueue.main.async { once(response) } }
        }
    }

    func surfaceSlots(_ id: PluginID) -> [PluginSlot] {
        catalog.plugins[id]?.manifest.kinds.filter(\.isSurface).compactMap { slots[SlotKey(id: id, kind: $0)] } ?? []
    }

    private func surfaceSlot(_ address: SurfaceAddress) -> PluginSlot? {
        catalog.plugins[address.plugin]?.manifest.surfaceKind(address.surface).flatMap { slots[SlotKey(id: address.plugin, kind: $0)] }
    }

    private func shownSlot(_ address: SurfaceAddress) -> PluginSlot? {
        surfaceSlot(address).flatMap { $0.shown[address.surface] == nil ? nil : $0 }
    }

    private func pointerDisplay() -> String? {
        let pointer = NSEvent.mouseLocation
        return displays.first { NSMouseInRect(pointer, $0.frame, false) }?.id
    }

    func toggle(_ address: SurfaceAddress, _ trace: Trace, origin: CGRect? = nil, _ reply: ((Response) -> Void)? = nil) {
        if shownSlot(address) != nil {
            let response = hide(address, trace)
            reply?(response)
        } else {
            summon(address, trace, origin: origin, reply)
        }
    }

    func summon(_ address: SurfaceAddress, _ trace: Trace, origin: CGRect? = nil, _ reply: ((Response) -> Void)? = nil) {
        guard let slot = surfaceSlot(address) else {
            reply?(.failure(surfaceSlots(address.plugin)
                    .isEmpty ? "no enabled surface \(address.plugin)" : "\(address.plugin) has no surface \(address.surface)"))
            return
        }
        show(address.surface, in: slot, trace, origin: origin, reply)
    }

    private func show(_ surface: String, in slot: PluginSlot, _ trace: Trace, origin: CGRect?, _ reply: ((Response) -> Void)?) {
        if let reason = slot.disabledReason {
            reply?(.failure("\(slot.key.id) is disabled: \(reason)"))
            return
        }
        if slot.shown[surface] != nil, slot.runtime != nil {
            reply?(.ok("shown"))
            return
        }
        slot.shown[surface] = ShownSurface(focused: pointerDisplay(), origin: origin)
        if let reply {
            slot.waiters.append(reply)
        }
        if let runtime = slot.runtime {
            runtime.setScene(scene(for: slot), trace)
        } else if slot.candidate == nil {
            load(slot, trace)
        }
    }

    func hide(_ address: SurfaceAddress, _ trace: Trace) -> Response {
        guard let slot = shownSlot(address) else {
            return surfaceSlots(address.plugin).isEmpty ? .failure("no enabled surface \(address.plugin)") : .ok("hidden")
        }
        return hide(address.surface, in: slot, trace)
    }

    func hide(_ surface: String, in slot: PluginSlot, _ trace: Trace) -> Response {
        guard slot.shown.removeValue(forKey: surface) != nil else { return .ok("hidden") }
        if slot.key.id == .onboarding {
            recordOnboardingDismissed()
        }
        if slot.visible || slot.bundle.manifest.keepLoaded {
            unmount(slot.key, surface: surface)
            slot.runtime?.setScene(scene(for: slot), trace)
        } else {
            stop(slot)
        }
        if !slot.visible {
            slot.answerWaiters(.ok("hidden"))
        }
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
                case .running where (manifest.surfaces[kind]?.count ?? 0) > 1:
                    return "\(kind.rawValue):" + (manifest.surfaces[kind] ?? []).map { "\($0)=\(slot.shown[$0] != nil ? "shown" : "hidden")" }
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
