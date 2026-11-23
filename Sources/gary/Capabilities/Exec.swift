import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

nonisolated extension Capability {
    static let exec = Capability(
        name: "exec",
        summary: """
        Run a command off the main thread. Gary looks the command up in the PATH of the user's login shell, \
        so commands from Homebrew and `~/.local/bin` need no absolute path, and stops every running command when the plugin stops. \
        `host.exec` runs a one-shot command and resolves with its exit status and output when it exits, even if it left a child \
        running in the background. Gary stops an `exec` command that runs longer than 60 seconds and rejects the promise. \
        `host.spawn` runs a long-running command with no time limit and calls `onLine` with each line it writes to stdout, \
        without the newline. `stop()` stops it. `exited` resolves when it exits, with its status and the last 4 KB of its stderr, \
        or with status -1 when it could not start or was stopped before it started.
        """,
        types: """
        declare namespace Gary {
          interface Host {
            exec(argv: string[]): Promise<ExecResult>;
            spawn(argv: string[], onLine: (line: string) => void): SpawnApi;
          }
          type ExecResult = { status: number; stdout: string; stderr: string }
          interface SpawnApi { exited: Promise<SpawnExit>; stop(): void }
          type SpawnExit = { status: number; stderr: string }
        }
        """,
        example: """
        let uptime = "…";
        let lastLogin = "";

        async function refresh() {
          const result = await host.exec(["/usr/bin/uptime"]);
          uptime = result.status === 0 ? result.stdout.replace(/.*up\\s+([^,]+),.*/s, "$1") : "?";
        }
        refresh();
        setInterval(refresh, 60_000);

        host.spawn(["/usr/bin/log", "stream", "--style", "compact", "--process", "loginwindow"], (line) => {
          lastLogin = line;
        });

        export default {
          render() {
            return { type: "text", text: lastLogin === "" ? uptime : `${uptime} · ${lastLogin}` };
          },
        } satisfies Gary.BarWidget;
        """,
        install: { host, plugin in
            let runs = ExecRuns(queue: plugin.queue)
            let spawns = SpawnRuns(queue: plugin.queue)
            plugin.onStop {
                runs.stopAll()
                spawns.stopAll()
            }
            plugin.installAPI(host, nil, ["exec"]) { call in
                let argv = try call.strings(0, "argv")
                guard !argv.isEmpty else { throw call.fail("argv must not be empty") }
                return .pending { finish in runs.start(argv, finish) }
            }
            let start = spawner(spawns, for: plugin)
            let stop: @convention(block) (Int) -> Void = { id in spawns.stop(id) }
            host.context.evaluateScript(spawnScript).call(withArguments: [host, start, stop])
        },
    )
}

private nonisolated let spawnScript = """
(function (host, start, stop) {
  host.spawn = function (argv, onLine) {
    if (typeof onLine !== "function") throw new TypeError("host.spawn: onLine must be a function");
    var finish;
    var exited = new Promise(function (resolve) { finish = resolve; });
    var id = start(JSON.stringify(argv), function (lines) { lines.forEach(function (line) { onLine(line); }); }, finish);
    return { exited: exited, stop: function () { stop(id); } };
  };
})
"""

final nonisolated class ExecRuns: @unchecked Sendable {
    private struct Run {
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
        let finish: @Sendable (Result<JSON, Error>) -> Void
    }

    private let queue: DispatchQueue
    private let limit: TimeInterval
    private var runs: [ObjectIdentifier: Run] = [:]
    private var stopped = false

    init(queue: DispatchQueue, limit: TimeInterval = 60) {
        self.queue = queue
        self.limit = limit
    }

    func start(_ argv: [String], _ finish: @escaping @Sendable (Result<JSON, Error>) -> Void) {
        queue.async { [self] in
            if !stopped {
                launch(argv, finish)
            }
        }
    }

    private func launch(_ argv: [String], _ finish: @escaping @Sendable (Result<JSON, Error>) -> Void) {
        let process = command(argv)
        let id = ObjectIdentifier(process)
        do {
            let stdout = try scratchFile()
            let stderr = try scratchFile()
            process.standardOutput = stdout.writer
            process.standardError = stderr.writer
            try LiveCommands.shared.run(process) { [weak self] in self?.queue.async { [weak self] in self?.exited(id) } }
            runs[id] = Run(process: process, stdout: stdout.reader, stderr: stderr.reader, finish: finish)
        } catch {
            finish(.success(result(status: -1, stdout: "", stderr: "\(error)")))
            return
        }
        queue.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, let run = runs.removeValue(forKey: id) else { return }
            run.process.terminate()
            run.finish(.failure(HostFailure("\(argv[0]) ran longer than \(Int(limit)) seconds and was stopped")))
        }
    }

    func stopAll() {
        stopped = true
        for run in runs.values {
            run.process.terminate()
        }
        runs = [:]
    }

    private func exited(_ id: ObjectIdentifier) {
        guard let run = runs.removeValue(forKey: id) else { return }
        run.finish(.success(result(
            status: Int(run.process.terminationStatus),
            stdout: String(decoding: run.stdout.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: run.stderr.readDataToEndOfFile(), as: UTF8.self),
        )))
    }
}

private nonisolated func spawner(_ spawns: SpawnRuns, for plugin: PluginRuntime) -> @convention(block) (String, JSValue, JSValue) -> Int {
    { [weak plugin] text, deliver, finish in
        guard let plugin else { return 0 }
        let call = HostCall(api: nil, method: "spawn", arguments: [(try? JSON.parse(text)) ?? .null])
        do {
            let argv = try call.strings(0, "argv")
            guard !argv.isEmpty else { throw call.fail("argv must not be empty") }
            return spawns.start(
                argv,
                lines: { [weak plugin] lines in plugin?.assumeIsolated { $0.callBack(deliver, [lines], Trace("spawn")) } },
                exit: { [weak plugin] status, stderr in
                    plugin?.assumeIsolated { $0.callBack(finish, [["status": status, "stderr": stderr]], Trace("spawn")) }
                },
            )
        } catch {
            let context = JSContext.current()
            context?.exception = context?.newError("\(error)")
            return 0
        }
    }
}

final nonisolated class SpawnRuns: @unchecked Sendable {
    private final class Run: @unchecked Sendable {
        let process: Process
        let lines: ([String]) -> Void
        let exit: (Int, String) -> Void
        var stdout: PipeReader?
        var stderr: PipeReader?
        var buffer = LineBuffer()
        var errors = Data()

        init(_ process: Process, lines: @escaping ([String]) -> Void, exit: @escaping (Int, String) -> Void) {
            self.process = process
            self.lines = lines
            self.exit = exit
        }

        func read(_ data: Data) {
            let complete = buffer.append(data)
            if !complete.isEmpty {
                lines(complete)
            }
        }

        func keep(_ data: Data) {
            errors = (errors + data).suffix(4096)
        }

        func close() {
            stdout?.close()
            stderr?.close()
        }
    }

    private let queue: DispatchQueue
    private var runs: [Int: Run] = [:]
    private var nextID = 1
    private var stopped = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(_ argv: [String], lines: @escaping ([String]) -> Void, exit: @escaping (Int, String) -> Void) -> Int {
        let id = nextID
        nextID += 1
        runs[id] = Run(command(argv), lines: lines, exit: exit)
        queue.async { [self] in launch(id) }
        return id
    }

    private func launch(_ id: Int) {
        guard !stopped, let run = runs[id] else { return }
        let stdout = Pipe()
        let stderr = Pipe()
        run.process.standardOutput = stdout
        run.process.standardError = stderr
        do {
            try LiveCommands.shared.run(run.process) { [weak self] in self?.queue.async { [weak self] in self?.exited(id) } }
        } catch {
            runs[id] = nil
            run.exit(-1, "\(error)")
            return
        }
        run.stdout = PipeReader(stdout.fileHandleForReading, queue: queue) { [weak run] in run?.read($0) }
        run.stderr = PipeReader(stderr.fileHandleForReading, queue: queue) { [weak run] in run?.keep($0) }
    }

    func stop(_ id: Int) {
        guard let run = runs[id] else { return }
        guard run.process.processIdentifier != 0 else {
            runs[id] = nil
            queue.async { run.exit(-1, "") }
            return
        }
        run.process.terminate()
    }

    func stopAll() {
        stopped = true
        for run in runs.values where run.process.processIdentifier != 0 {
            run.process.terminate()
            run.close()
        }
        runs = [:]
    }

    private func exited(_ id: Int) {
        guard let run = runs.removeValue(forKey: id) else { return }
        run.stdout?.drain()
        run.stderr?.drain()
        run.close()
        let rest = run.buffer.flush()
        if !rest.isEmpty {
            run.lines(rest)
        }
        run.exit(Int(run.process.terminationStatus), String(decoding: run.errors, as: UTF8.self))
    }
}

private final nonisolated class PipeReader {
    private let handle: FileHandle
    private let source: DispatchSourceRead
    private let receive: (Data) -> Void

    init(_ handle: FileHandle, queue: DispatchQueue, receive: @escaping (Data) -> Void) {
        self.handle = handle
        self.receive = receive
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    func drain() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !source.isCancelled {
            let count = read(handle.fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                receive(Data(chunk[0..<count]))
            } else {
                if count == 0 {
                    source.cancel()
                }
                return
            }
        }
    }

    func close() {
        source.cancel()
    }
}

private nonisolated struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[..<last]
        pending = Data(pending[(last + 1)...])
        return complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    mutating func flush() -> [String] {
        defer { pending = Data() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}

final nonisolated class LiveCommands: @unchecked Sendable {
    static let shared = LiveCommands()
    private let lock = NSLock()
    private var running: Set<pid_t> = []

    private init() {
        atexit { LiveCommands.shared.stopAll() }
    }

    func run(_ process: Process, exited: @escaping @Sendable () -> Void) throws {
        process.terminationHandler = { [self] process in
            lock.withLock { _ = running.remove(process.processIdentifier) }
            exited()
        }
        try lock.withLock {
            try process.run()
            running.insert(process.processIdentifier)
        }
    }

    func stopAll() {
        for pid in lock.withLock({ running }) {
            kill(pid, SIGTERM)
        }
    }
}

private nonisolated func command(_ argv: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["--"] + argv
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    return process
}

private nonisolated func result(status: Int, stdout: String, stderr: String) -> JSON {
    .object(["status": .number(Double(status)), "stdout": .string(stdout), "stderr": .string(stderr)])
}

private nonisolated func scratchFile() throws -> (writer: FileHandle, reader: FileHandle) {
    let url = FileManager.default.temporaryDirectory.appending(path: "gary-exec-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw HostFailure("cannot create \(url.path)") }
    defer { try? FileManager.default.removeItem(at: url) }
    return try (FileHandle(forWritingTo: url), FileHandle(forReadingFrom: url))
}

private nonisolated let searchPath = [Bundle.main.executableURL?.deletingLastPathComponent().path, loginPath].compactMap(\.self)
    .joined(separator: ":")

private nonisolated let loginPath: String = {
    let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell.map({ String(cString: $0) }) else { return fallback }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "exec /usr/bin/printenv PATH"]
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return fallback
    }
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    let path = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    return process.terminationStatus == 0 && path.contains("/") ? path : fallback
}()
