import Foundation
import GaryCore

extension Capability {
    static let focus = Capability(name: "focus", types: """
    declare namespace Gary {
      interface State { focus?: Focus }
      interface Focus {
        available: boolean;
        active: boolean;
        reason?: string;
        mode?: string | null;
        name?: string | null;
        symbol?: string | null;
        source?: string | null;
      }
    }
    """, permissions: [.fullDiskAccess], topic: { FocusTopic($0) })
}

private final class FocusTopic {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/DoNotDisturb/DB")
    private let publish: (JSON, Trace) -> Void
    private var observations: [Observation] = []

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        let watch = PathWatch(["", "Assertions.json", "ModeConfigurations.json"].map { Self.directory.appending(path: $0).path }, queue: DispatchQueue(label: "gary.focus")) { [weak self] in
            self?.send(Trace("focus"))
        }
        let next = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.send(Trace("focus-minute")) }
        RunLoop.main.add(timer, forMode: .common)
        observations = [Observation { watch.stop() }, Observation { timer.invalidate() }]
        send(Trace("focus-start"))
    }

    private func send(_ trace: Trace) {
        let state: FocusState?
        do {
            let assertions = try Data(contentsOf: Self.directory.appending(path: "Assertions.json"))
            let configurations = try Data(contentsOf: Self.directory.appending(path: "ModeConfigurations.json"))
            state = try FocusState.resolve(assertions: assertions, configurations: configurations, at: Date(), calendar: .current)
        } catch let error as FocusState.FileError {
            return publish(.object(["available": .bool(false), "reason": .string(error.description), "active": .bool(false)]), trace)
        } catch {
            return publish(.object(["available": .bool(false), "reason": .string("Gary needs Full Disk Access to read Focus state"), "active": .bool(false)]), trace)
        }
        guard let state else { return publish(.object(["available": .bool(true), "active": .bool(false), "mode": .null, "name": .null, "symbol": .null, "source": .null]), trace) }
        publish(.object([
            "available": .bool(true), "active": .bool(true), "mode": .string(state.mode),
            "name": state.name.map(JSON.string) ?? .null, "symbol": state.symbol.map(JSON.string) ?? .null, "source": .string(state.source.rawValue),
        ]), trace)
    }
}
