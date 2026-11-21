import AppKit
import GaryCore
import GaryDinky
import GaryPrivate
import GarySocket

final class WorkspacesProvider {
    private let hub: StateHub
    private let dinky = DinkyClient()
    private let queue = DispatchQueue(label: "gary.workspaces", qos: .userInteractive)
    private var names = WorkspaceNames.native
    private var settle: DispatchWorkItem?

    init(hub: StateHub) { self.hub = hub }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let registered = gary_space_events_start({ event, context in
            let trace = Trace("sls\(event.rawValue)")
            let provider = Unmanaged<WorkspacesProvider>.fromOpaque(context!).takeUnretainedValue()
            if event == .changed { provider.spaceChanged(trace) } else { provider.topologyChanged(trace) }
        }, context)
        log("workspaces: SkyLight space events \(registered ? "registered" : "unavailable")")
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged(Trace("nsworkspace"))
        }
        queue.async { [self] in
            refreshNames()
            publish(Trace("workspaces-start"))
        }
    }

    func spaceChanged(_ trace: Trace) {
        if tracing { log(String(format: "space-event src=%@ t0=%.6f", trace.cause, trace.start)) }
        queue.async { [self] in
            publish(trace)
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settled() }
            settle = work
            queue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func topologyChanged(_ trace: Trace) {
        queue.async { [self] in
            refreshNames()
            publish(trace)
        }
    }

    private func live() -> [DisplaySpaces] {
        gary_display_spaces().map { display in
            DisplaySpaces(uuid: display.uuid, current: SpaceID(display.currentSpaceID), spaces: display.userSpaceIDs.map { SpaceID($0.uint64Value) })
        }
    }

    private func publish(_ trace: Trace) {
        hub.publish(names.snapshot(live: live(), active: SpaceID(gary_active_space())), trace)
    }

    private func settled() {
        switch names {
        case .native:
            refreshNames()
        case .mapped:
            if !live().allSatisfy({ names.knows($0.current) }) { refreshNames() }
        case .learned(let rows, var map):
            if let name = try? parseFocusedWorkspace(dinky.run(focusedWorkspaceCommand)) {
                map.learn(name, on: SpaceID(gary_active_space()))
            }
            names = .learned(rows: rows, map: map)
        }
        publish(Trace("settled"))
    }

    private func refreshNames(retrying: Bool = false) {
        let previous = names
        do {
            names = .mapped(try WorkspaceMap.parseDebugState(try dinky.run("debug-state")))
        } catch SocketError.unreachable where !FileManager.default.fileExists(atPath: dinky.path) {
            names = .native
        } catch let error as SocketError {
            log("workspaces: dinky did not answer (\(error)); keeping names from \(source(names))")
            if !retrying {
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    refreshNames(retrying: true)
                    publish(Trace("retry"))
                }
            }
        } catch {
            if case .learned = previous {} else { log("workspaces: \(error); learning names from list-workspaces instead") }
            var map = WorkspaceMap()
            if case .learned(_, let known) = previous { map = known }
            if let name = try? parseFocusedWorkspace(dinky.run(focusedWorkspaceCommand)) { map.learn(name, on: SpaceID(gary_active_space())) }
            names = .learned(rows: (try? parseWorkspaceRows(dinky.run(workspaceRowsCommand))) ?? [], map: map)
        }
        if source(previous) != source(names) { log("workspaces: names from \(source(names))") }
    }

    private func source(_ names: WorkspaceNames) -> String {
        switch names {
        case .native: return "native Spaces"
        case .mapped: return "dinky debug-state"
        case .learned: return "dinky list-workspaces, learned per Space"
        }
    }
}

enum DinkyCommands {
    private static let queue = DispatchQueue(label: "gary.dinky", qos: .userInitiated)
    private static let client = DinkyClient()

    static func send(_ command: String, from plugin: PluginID) {
        queue.async {
            do {
                _ = try client.run(command)
            } catch {
                log("plugin \(plugin): dinky \(command): \(error)")
            }
        }
    }
}
