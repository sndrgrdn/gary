import AppKit
import GaryCore
import JavaScriptCore

private nonisolated let garbageMarkersKey = "JSC_numberOfGCMarkers"

func runApp() -> Int32 {
    unsetenv(spaceEfficientMallocKey)
    setenv(garbageMarkersKey, "1", 0)
    JSStringRelease(JSStringCreateWithUTF8CString("gary"))
    unsetenv(systemMallocKey)
    unsetenv(garbageMarkersKey)
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)
    guard holdLock(Paths.appLock) else {
        fputs("gary: already running\n", stderr)
        return ProcessExit.alreadyRunning
    }
    ExitWatchdog.shared.start()
    if Paths.isolated {
        log("isolated: home \(Paths.home.path), runtime \(Paths.runtime.path), drives the system: \(Paths.drivesSystem)")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    #if DEBUG
        MainThreadWatchdog.start()
    #endif
    let shell: Shell
    do {
        shell = try Shell()
        try shell.start()
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 1
    }
    withExtendedLifetime(shell) { app.run() }
    return 0
}
