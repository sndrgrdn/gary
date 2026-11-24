import Foundation

final nonisolated class ExitWatchdog: @unchecked Sendable {
    static let shared = ExitWatchdog()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var writer: Int32 = -1

    func start() {
        lock.withLock { _ = spawn() }
    }

    func track(_ child: pid_t) {
        send("+\(child)")
    }

    func untrack(_ child: pid_t) {
        send("-\(child)")
    }

    private func send(_ line: String) {
        lock.withLock {
            guard writer >= 0 else { return }
            let bytes = Array("\(line)\n".utf8)
            _ = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        }
    }

    private func spawn() -> Bool {
        guard pid == 0 else { return writer >= 0 }
        guard let path = Bundle.main.executablePath else { return false }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            log("exit watchdog not started: \(String(cString: strerror(errno)))")
            pid = -1
            return false
        }
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, ends[0], 0)
        posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["gary-restore", "restore-after", String(getpid())]
        let argv = arguments.map { strdup($0) } + [nil]
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        for argument in argv {
            free(argument)
        }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(ends[0])
        guard status == 0 else {
            log("exit watchdog not started: \(String(cString: strerror(status)))")
            close(ends[1])
            pid = -1
            return false
        }
        writer = ends[1]
        return true
    }
}

func runRestoreAfter(_ arguments: [String]) -> Int32 {
    guard let pid = arguments.first.flatMap(Int32.init) else { return 64 }
    var children: Set<pid_t> = []
    var pending = ""
    func readCommands() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        guard count > 0 else { return false }
        pending += String(decoding: chunk[0..<count], as: UTF8.self)
        while let newline = pending.firstIndex(of: "\n") {
            let line = pending[..<newline]
            pending = String(pending[pending.index(after: newline)...])
            guard let child = Int32(line.dropFirst()) else { continue }
            if line.first == "+" {
                children.insert(child)
            } else {
                children.remove(child)
            }
        }
        return true
    }
    func finish() -> Never {
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        while readCommands() {
            continue
        }
        log("restore watchdog: gary \(pid) exited")
        SystemState.restore()
        for child in children {
            kill(-child, SIGTERM)
        }
        if !children.isEmpty {
            log("restore watchdog: stopped \(children.count) commands gary left running")
        }
        exit(0)
    }
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    input.setEventHandler {
        if !readCommands() {
            finish()
        }
    }
    let exited = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    exited.setEventHandler { finish() }
    input.resume()
    exited.resume()
    if kill(pid, 0) != 0 {
        SystemState.restore()
        return 0
    }
    dispatchMain()
}
