import AppKit
import GaryCore
import GaryPrivate

nonisolated enum SkyLight {
    private static let connection = privateSymbol(.mainConnectionID, as: (@convention(c) () -> Int32).self)
    private static let setAlpha = privateSymbol(.setMenuBarInsetAndAlpha, as: (@convention(c) (Int32, Double, Double, Float) -> Int32).self)
    private static let getDock = privateSymbol(
        .getDockRect,
        as: (@convention(c) (
            Int32,
            UnsafeMutablePointer<CGRect>,
            UnsafeMutablePointer<Int32>,
            UnsafeMutablePointer<Int32>,
        ) -> Int32).self,
    )
    private static let setDock = privateSymbol(.setDockRect, as: (@convention(c) (Int32, CGRect, Int32, Int32) -> Int32).self)

    static func missing(_ symbols: [GarySymbol]) -> String? {
        let absent = missingSymbols(symbols)
        return absent.isEmpty ? nil : "\(absent.joined(separator: ", ")) is missing from SkyLight on this macOS"
    }

    static let menuBarSymbols: [GarySymbol] = [.mainConnectionID, .setMenuBarInsetAndAlpha]
    static let dockSymbols: [GarySymbol] = [.mainConnectionID, .getDockRect, .setDockRect]

    static func setMenuBarAlpha(_ alpha: Float) {
        guard let connection, let setAlpha else { return }
        _ = setAlpha(connection(), 0, 1, alpha)
    }

    static func dockRect() -> DockRect? {
        guard let connection, let getDock else { return nil }
        var rect = CGRect.zero
        var reason: Int32 = 0
        var orientation: Int32 = 0
        guard getDock(connection(), &rect, &reason, &orientation) == 0 else { return nil }
        return DockRect(rect: rect, reason: reason, orientation: orientation)
    }

    static func setDockRect(_ dock: DockRect) {
        guard let connection, let setDock else { return }
        _ = setDock(connection(), dock.rect, dock.reason, dock.orientation)
    }
}

nonisolated enum CoreDock {
    private static let read = privateSymbol(.dockGetAutoHide, as: (@convention(c) () -> Bool).self)
    private static let write = privateSymbol(.dockSetAutoHide, as: (@convention(c) (Bool) -> Void).self)

    static var missing: String? {
        read == nil || write == nil ? "CoreDockGetAutoHideEnabled or CoreDockSetAutoHideEnabled is missing on this macOS" : nil
    }

    static var visibility: DockVisibility {
        DockVisibility(rawValue: read?() ?? false)
    }

    static func setVisibility(_ visibility: DockVisibility) {
        write?(visibility.rawValue)
    }
}

nonisolated enum DockVisibility: RawRepresentable, Codable, Equatable {
    case autohide
    case shown

    init(rawValue autohide: Bool) {
        self = autohide ? .autohide : .shown
    }

    var rawValue: Bool {
        switch self {
        case .autohide: true
        case .shown: false
        }
    }
}

nonisolated struct DockRect: Codable, Equatable {
    var rect: CGRect
    var reason: Int32
    var orientation: Int32
}

nonisolated struct SavedSystemState: Codable, Equatable {
    struct Dock: Codable, Equatable {
        var own: DockRect
        var reserved: DockRect
    }

    private enum CodingKeys: String, CodingKey {
        case menuBarHidden, dock, capsLock
        case dockVisibility = "autohide"
    }

    var menuBarHidden = false
    var dock: Dock?
    var dockVisibility: DockVisibility?
    var capsLock: [String: [HyperKey.Mapping]]?
}

nonisolated enum SystemState {
    static let queue = DispatchQueue(label: "gary.system-state", qos: .userInitiated)
    private static let lock = NSLock()
    private nonisolated(unsafe) static var current = SavedSystemState()

    static var saved: SavedSystemState {
        lock.withLock { current }
    }

    static func update(_ change: (inout SavedSystemState) -> Void) {
        var next = saved
        change(&next)
        guard next != saved else { return }
        lock.withLock { current = next }
        if next == SavedSystemState() {
            try? FileManager.default.removeItem(at: Paths.systemRestore)
            return
        }
        do {
            try FileManager.default.createDirectory(at: Paths.systemRestore.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: Paths.systemRestore, options: .atomic)
        } catch {
            log("system state not saved: \(error)")
        }
        ExitWatchdog.shared.start()
    }

    static func restore(_ state: SavedSystemState? = nil) {
        let file = (try? Data(contentsOf: Paths.systemRestore)).flatMap { try? JSONDecoder().decode(SavedSystemState.self, from: $0) }
        guard let state = state ?? file, state != SavedSystemState() else { return }
        if state.menuBarHidden {
            SkyLight.setMenuBarAlpha(1)
        }
        if let dock = state.dock, SkyLight.dockRect()?.rect == dock.reserved.rect {
            SkyLight.setDockRect(dock.own)
        }
        if let visibility = state.dockVisibility, CoreDock.visibility != visibility {
            CoreDock.setVisibility(visibility)
        }
        if let capsLock = state.capsLock {
            Keyboards.giveBack(capsLock)
        }
        try? FileManager.default.removeItem(at: Paths.systemRestore)
        lock.withLock { current = SavedSystemState() }
        log(
            "restored the system state Gary had changed: menubar hidden=\(state.menuBarHidden) dock=\(state.dock?.own.rect.debugDescription ?? "-") autohide=\(state.dockVisibility.map { String($0.rawValue) } ?? "-") capslock=\(state.capsLock != nil)",
        )
    }
}
