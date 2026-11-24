import AppKit

struct ParkedMount {
    let window: SurfaceWindow
    let view: TreeHostingView
}

final class ParkedMounts {
    static let lifetime: TimeInterval = 60

    private var parked: [MountKey: (mount: ParkedMount, turn: Int)] = [:]
    private var turn = 0
    private let later: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    init(later: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
    }) {
        self.later = later
    }

    func park(_ key: MountKey, _ mount: ParkedMount, fade: Double) {
        mount.window.hide(fade: fade)
        turn += 1
        let turn = turn
        parked[key] = (mount, turn)
        later(Self.lifetime) { [weak self] in
            guard let self, parked[key]?.turn == turn else { return }
            parked.removeValue(forKey: key)?.mount.window.panel.close()
        }
    }

    func take(_ key: MountKey) -> ParkedMount? {
        parked.removeValue(forKey: key)?.mount
    }
}
