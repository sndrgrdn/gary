import Foundation
@testable import gary
@testable import GaryCore
import Testing

final class FakeRuntime: SlotRuntime {
    let bundle: PluginBundle
    let initialScene: Scene
    var scene: Scene
    var started = false
    var stopped = false

    init(bundle: PluginBundle, scene: Scene) {
        self.bundle = bundle
        initialScene = scene
        self.scene = scene
    }
}

@MainActor
final class Lifecycle {
    typealias Effect = PluginSlots<FakeRuntime>.Effect

    private(set) var clock = 0.0
    private(set) var made: [FakeRuntime] = []
    private(set) var presented: [SlotKey] = []
    private(set) var unmounted: [String] = []
    private(set) var syncs = 0
    private var timers: [(due: Double, transition: () -> [Effect])] = []
    private(set) lazy var slots = PluginSlots<FakeRuntime>(
        make: { _, bundle, scene in
            let runtime = FakeRuntime(bundle: bundle, scene: scene)
            self.made.append(runtime)
            return runtime
        },
        scene: { _, shown in Scene(shown: shown) },
        clock: { self.clock },
    )

    var newest: FakeRuntime {
        get throws { try #require(made.last) }
    }

    func perform(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case let .start(runtime): runtime.started = true
            case let .stop(runtime): runtime.stopped = true
            case let .setScene(runtime, scene): runtime.scene = scene
            case let .present(key, _): presented.append(key)
            case let .unmount(key, surface): unmounted.append("\(key)" + (surface.map { ":\($0)" } ?? ""))
            case let .answer(waiters, response): waiters.forEach { $0(response) }
            case let .later(delay, _, transition): timers.append((clock + delay, transition))
            case .sync: syncs += 1
            }
        }
    }

    func advance(by seconds: Double) {
        let target = clock + seconds
        while let index = timers.indices.filter({ timers[$0].due <= target }).min(by: { timers[$0].due < timers[$1].due }) {
            let timer = timers.remove(at: index)
            clock = max(clock, timer.due)
            perform(timer.transition())
        }
        clock = target
    }

    func sync(_ wanted: [SlotKey: PluginBundle]) {
        perform(slots.sync(wanted))
    }

    func loaded(_ runtime: FakeRuntime, _ key: SlotKey, shows surfaces: [String] = [SurfaceAddress.main]) {
        perform(slots.loaded(runtime, at: key, RuntimeOutput(trees: Dictionary(uniqueKeysWithValues: surfaces.map { ($0, [:]) }))))
    }

    func failed(_ runtime: FakeRuntime, _ key: SlotKey, _ reason: String = "boom") {
        perform(slots.failed(runtime, at: key, reason))
    }

    func show(in key: SlotKey, _ surface: String = SurfaceAddress.main) -> Replies {
        let replies = Replies()
        perform(slots.show(surface, in: key, ShownSurface(), replies.add))
        return replies
    }

    func hide(in key: SlotKey, _ surface: String = SurfaceAddress.main) {
        perform(slots.hide(surface, in: key))
    }

    func use(_ key: SlotKey) -> Uses {
        let uses = Uses()
        perform(slots.use(key) { uses.runtimes.append($0) })
        return uses
    }

    func state(_ key: SlotKey) -> String {
        switch slots[key]?.phase {
        case nil: "none"
        case .stopped: "stopped"
        case .running: "running"
        case let .failed(reason): "failed(\(reason))"
        case .disabled: "disabled"
        }
    }
}

@MainActor
final class Replies {
    private(set) var all: [String] = []

    func add(_ response: Response) {
        switch response {
        case let .ok(text): all.append(text)
        case let .failure(reason): all.append("failure: \(reason)")
        }
    }
}

@MainActor
final class Uses {
    var runtimes: [FakeRuntime?] = []
}

func bundle(
    _ id: String,
    _ kind: PluginKind,
    version: String = "1",
    keepLoaded: Bool = false,
    surfaces: [String] = [SurfaceAddress.main],
) throws -> PluginBundle {
    let manifest = try PluginManifest(
        id: #require(PluginID(id)), name: id, version: version, kinds: [kind], entryPoints: [kind: "main.js"],
        keepLoaded: keepLoaded, subscriptions: [kind: []], uses: [], hotkeys: [],
        surfaces: kind.isSurface ? [kind: surfaces] : [:],
    )
    return PluginBundle(manifest: manifest, directory: URL(fileURLWithPath: "/p/\(id)"), origin: .user)
}

func key(_ id: String, _ kind: PluginKind) throws -> SlotKey {
    try SlotKey(id: #require(PluginID(id)), kind: kind)
}
