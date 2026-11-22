import AppKit
import GaryCore

func runApp() -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)
    guard holdLock(appLockPath) else {
        fputs("gary: already running\n", stderr)
        return ProcessExit.alreadyRunning
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
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
