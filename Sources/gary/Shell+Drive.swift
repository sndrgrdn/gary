import AppKit
import GaryCore

extension Shell {
    func drive(_ request: Request, _ reply: @escaping (Response) -> Void) {
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
            let focused = screens.windows.first { $0.key.slot.id == id && (kind == nil || $0.key.slot.kind == kind) && $0.value.panel.isKeyWindow }
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
        guard screens.mounts.keys.contains(where: { $0.slot == key }) else { return .failure("\(key) is not shown") }
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
        let pointer = screens.pointerDisplay()
        return screens.mounts.filter { $0.key.slot == key && !$0.value.isHidden }.sorted { $0.key.display == pointer && $1.key.display != pointer }
            .map(\.value)
    }

    private func describe(_ frame: CGRect) -> String {
        let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
        return String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, top, frame.width, frame.height)
    }
}
