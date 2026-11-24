import Foundation
import GaryCore
import ServiceManagement

private nonisolated let supervisedKey = "GARY_SUPERVISED"
nonisolated let spaceEfficientMallocKey = "MallocSpaceEfficient"
nonisolated let systemMallocKey = "Malloc"
nonisolated let isSupervised = ProcessInfo.processInfo.environment[supervisedKey] != nil

nonisolated func holdLock(_ path: String) -> Bool {
    try? FileManager.default.createDirectory(at: Paths.runtime, withIntermediateDirectories: true)
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
    }
    return true
}

func lockIsHeld(_ path: String) -> Bool {
    let fd = open(path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return flock(fd, LOCK_EX | LOCK_NB) != 0
}

private final nonisolated class Child: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopping = false

    func start(_ process: Process) -> Bool {
        lock.withLock {
            guard !stopping else { return false }
            self.process = process
            return (try? process.run()) != nil
        }
    }

    func stop(_ signal: Int32) {
        lock.withLock {
            stopping = true
            if let process, process.isRunning {
                kill(process.processIdentifier, signal)
            }
        }
    }

    var isStopping: Bool {
        lock.withLock { stopping }
    }
}

nonisolated func runSupervisor() -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard holdLock(Paths.supervisorLock) else {
        log("supervisor: another supervisor is running")
        return 0
    }
    let child = Child()
    let signals = [SIGTERM, SIGINT, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { child.stop(number) }
        source.resume()
        return source
    }
    return withExtendedLifetime(signals) { supervise(child) }
}

private nonisolated func supervise(_ child: Child) -> Int32 {
    var budget = RestartBudget(limit: 5, window: 60)
    while true {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["app"]
        process.environment = ProcessInfo.processInfo.environment
            .merging([supervisedKey: "1", spaceEfficientMallocKey: "1", systemMallocKey: "1"]) { $1 }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard child.start(process) else { return 0 }
        log("supervisor pid=\(getpid()): started gary pid=\(process.processIdentifier)")
        exited.wait()
        let exit: ProcessExit = process
            .terminationReason == .uncaughtSignal ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
        switch child.isStopping ? .stop : budget.step(after: exit, at: now()) {
        case .stop:
            log("supervisor: gary \(exit.description); not restarting")
            return 0
        case .giveUp:
            log("supervisor: gary \(exit.description); gave up after \(budget.summary), the limit is \(budget.limit)")
            return 1
        case .restartNow:
            log("supervisor: gary asked to restart (\(budget.summary), limit \(budget.limit))")
        case .restartAfterPause:
            log("supervisor: gary \(exit.description); restarting (\(budget.summary), limit \(budget.limit))")
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

func runLogin(_ arguments: [String]) -> Int32 {
    guard Bundle.main.bundleIdentifier != nil else {
        fputs("gary: login needs the app bundle; run the gary inside Gary.app\n", stderr)
        return 1
    }
    let service = SMAppService.mainApp
    do {
        switch arguments {
        case ["on"]: if service.status != .enabled {
                try service.register()
            }
        case ["off"]: if service.status == .enabled {
                try service.unregister()
            }
        case [], ["status"]: break
        default:
            fputs("usage: gary login [on|off|status]\n", stderr)
            return 64
        }
    } catch {
        fputs("gary: login item: \(error.localizedDescription)\n", stderr)
        return 1
    }
    print("login item \(service.status.name) for \(Bundle.main.bundlePath)")
    return 0
}

extension SMAppService.Status {
    var name: String {
        switch self {
        case .enabled: "on"
        case .notRegistered: "off"
        case .requiresApproval: "awaiting approval in System Settings > General > Login Items"
        case .notFound: "off (never registered)"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}
