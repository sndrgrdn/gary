import Foundation
import GaryCore

extension Capability {
    static let exec = Capability(
        name: "exec",
        summary: """
        Run a command off the main thread and get its exit status and output. Gary looks the command up in the PATH of the user's login shell, \
        so commands from Homebrew and `~/.local/bin` need no absolute path. The promise resolves when the command exits, even if it left a child \
        running in the background. Gary stops a command that runs longer than 60 seconds and rejects the promise, and stops every running command \
        when the plugin stops.
        """,
        types: """
        declare namespace Gary {
          interface Host { exec(argv: string[]): Promise<ExecResult> }
          interface ExecResult { status: number; stdout: string; stderr: string }
        }
        """,
        example: """
        let uptime = "…";

        async function refresh() {
          const result = await host.exec(["/usr/bin/uptime"]);
          uptime = result.status === 0 ? result.stdout.replace(/.*up\\s+([^,]+),.*/s, "$1") : "?";
        }
        refresh();
        setInterval(refresh, 60_000);

        export default {
          render() {
            return { type: "text", text: uptime };
          },
        } satisfies Gary.BarWidget;
        """,
        install: { host, plugin in
            let runs = ExecRuns(queue: plugin.queue)
            plugin.onStop { runs.stopAll() }
            plugin.installAPI(host, nil, ["exec"]) { call in
                let argv = try call.strings(0, "argv")
                guard !argv.isEmpty else { throw call.fail("argv must not be empty") }
                return .pending { finish in runs.start(argv, finish) }
            }
        },
    )
}

final class ExecRuns {
    private struct Run {
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
        let finish: (Result<JSON, Error>) -> Void
    }

    private let queue: DispatchQueue
    private let limit: TimeInterval
    private var runs: [ObjectIdentifier: Run] = [:]

    init(queue: DispatchQueue, limit: TimeInterval = 60) {
        self.queue = queue
        self.limit = limit
    }

    func start(_ argv: [String], _ finish: @escaping (Result<JSON, Error>) -> Void) {
        let process = Process()
        let id = ObjectIdentifier(process)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["--"] + argv
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.queue.async { self?.exited(id) } }
        do {
            let stdout = try scratchFile()
            let stderr = try scratchFile()
            process.standardOutput = stdout.writer
            process.standardError = stderr.writer
            try process.run()
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

private func result(status: Int, stdout: String, stderr: String) -> JSON {
    .object(["status": .number(Double(status)), "stdout": .string(stdout), "stderr": .string(stderr)])
}

private func scratchFile() throws -> (writer: FileHandle, reader: FileHandle) {
    let url = FileManager.default.temporaryDirectory.appending(path: "gary-exec-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw HostFailure("cannot create \(url.path)") }
    defer { try? FileManager.default.removeItem(at: url) }
    return try (FileHandle(forWritingTo: url), FileHandle(forReadingFrom: url))
}

private let searchPath = [Bundle.main.executableURL?.deletingLastPathComponent().path, loginPath].compactMap(\.self).joined(separator: ":")

private let loginPath: String = {
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
