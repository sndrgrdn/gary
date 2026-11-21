import AppKit

enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }

    private static let connection = symbol("SLSMainConnectionID", (@convention(c) () -> Int32).self)
    private static let setAlpha = symbol("SLSSetMenuBarInsetAndAlpha", (@convention(c) (Int32, Double, Double, Float) -> Int32).self)
    private static let getDock = symbol("SLSGetDockRectWithOrientation",
                                        (@convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self)
    private static let setDock = symbol("SLSSetDockRectWithOrientation", (@convention(c) (Int32, CGRect, Int32, Int32) -> Int32).self)

    static func missing(_ names: [String]) -> String? {
        let absent = names.filter { dlsym(handle, $0) == nil }
        return absent.isEmpty ? nil : "\(absent.joined(separator: ", ")) is missing from SkyLight on this macOS"
    }

    static let menuBarSymbols = ["SLSMainConnectionID", "SLSSetMenuBarInsetAndAlpha"]
    static let dockSymbols = ["SLSMainConnectionID", "SLSGetDockRectWithOrientation", "SLSSetDockRectWithOrientation"]

    static func setMenuBarAlpha(_ alpha: Float) {
        guard let connection, let setAlpha else { return }
        _ = setAlpha(connection(), 0, 1, alpha)
    }

    static func dockRect() -> DockRect? {
        guard let connection, let getDock else { return nil }
        var rect = CGRect.zero, reason: Int32 = 0, orientation: Int32 = 0
        guard getDock(connection(), &rect, &reason, &orientation) == 0 else { return nil }
        return DockRect(rect: rect, reason: reason, orientation: orientation)
    }

    static func setDockRect(_ dock: DockRect) {
        guard let connection, let setDock else { return }
        _ = setDock(connection(), dock.rect, dock.reason, dock.orientation)
    }
}

enum CoreDock {
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let read = dlsym(handle, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: (@convention(c) () -> Bool).self) }
    private static let write = dlsym(handle, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: (@convention(c) (Bool) -> Void).self) }

    static var missing: String? {
        read == nil || write == nil ? "CoreDockGetAutoHideEnabled or CoreDockSetAutoHideEnabled is missing on this macOS" : nil
    }

    static var autohide: Bool { read?() ?? false }

    static func setAutohide(_ on: Bool) { write?(on) }
}

struct DockRect: Codable, Equatable {
    var rect: CGRect
    var reason: Int32
    var orientation: Int32
}

struct SavedSystemState: Codable, Equatable {
    struct Dock: Codable, Equatable {
        var own: DockRect
        var reserved: DockRect
    }

    var menuBarHidden = false
    var dock: Dock?
    var autohide: Bool?
}

enum SystemState {
    static private(set) var saved = SavedSystemState()
    private static var watchdog: pid_t = 0

    static func update(_ change: (inout SavedSystemState) -> Void) {
        var next = saved
        change(&next)
        guard next != saved else { return }
        saved = next
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
        startWatchdog()
    }

    static func restore(_ state: SavedSystemState? = nil) {
        let file = (try? Data(contentsOf: Paths.systemRestore)).flatMap { try? JSONDecoder().decode(SavedSystemState.self, from: $0) }
        guard let state = state ?? file, state != SavedSystemState() else { return }
        if state.menuBarHidden { SkyLight.setMenuBarAlpha(1) }
        if let dock = state.dock, SkyLight.dockRect()?.rect == dock.reserved.rect { SkyLight.setDockRect(dock.own) }
        if let autohide = state.autohide, CoreDock.autohide != autohide { CoreDock.setAutohide(autohide) }
        try? FileManager.default.removeItem(at: Paths.systemRestore)
        saved = SavedSystemState()
        log("restored the system state Gary had changed: menubar hidden=\(state.menuBarHidden) dock=\(state.dock?.own.rect.debugDescription ?? "-") autohide=\(state.autohide.map(String.init) ?? "-")")
    }

    private static func startWatchdog() {
        guard watchdog == 0, let path = Bundle.main.executablePath else { return }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ["gary-restore", "restore-after", String(getpid())].map { strdup($0) } + [nil]
        let status = posix_spawn(&watchdog, path, &actions, &attributes, argv, environ)
        for argument in argv { free(argument) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        if status != 0 { log("restore watchdog not started: \(String(cString: strerror(status)))") }
    }
}

func runRestoreAfter(_ arguments: [String]) -> Int32 {
    guard let pid = arguments.first.flatMap(Int32.init) else { return 64 }
    let exited = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    exited.setEventHandler {
        log("restore watchdog: gary \(pid) exited")
        SystemState.restore()
        exit(0)
    }
    exited.resume()
    if kill(pid, 0) != 0 {
        SystemState.restore()
        return 0
    }
    dispatchMain()
}
