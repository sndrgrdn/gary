import Foundation
import JavaScriptCore

extension Capability {
    static let exec = Capability(
        name: "exec",
        summary: """
        Run a command off the main thread and get its exit status and output. Gary looks the command up in the PATH of the user's login shell, \
        so commands from Homebrew and `~/.local/bin` need no absolute path.
        """,
        types: """
        declare namespace Gary {
          interface Host { exec(argv: string[], callback: (result: ExecResult) => void): void }
          interface ExecResult { status: number; stdout: string; stderr: string }
        }
        """,
        example: """
        let uptime = "…";

        function refresh() {
          host.exec(["/usr/bin/uptime"], (result) => {
            uptime = result.status === 0 ? result.stdout.replace(/.*up\\s+([^,]+),.*/s, "$1") : "?";
          });
        }
        refresh();
        setInterval(refresh, 60_000);

        module.exports = {
          render() {
            return { type: "text", text: uptime };
          },
        } satisfies Gary.BarWidget;
        """,
        install: { host, plugin in
            let exec: @convention(block) (JSValue, JSValue) -> Void = { [weak plugin] argv, callback in
                guard let argv = argv.toArray() as? [String], !argv.isEmpty, callback.isObject else {
                    let context = JSContext.current()
                    context?.exception = context?.newError("host.exec takes an array of strings and a callback")
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = runProcess(argv)
                    plugin?.queue.async {
                        plugin?.callBack(callback, [["status": output.status, "stdout": output.stdout, "stderr": output.stderr]], Trace("exec"))
                    }
                }
            }
            host.setObject(exec, forKeyedSubscript: "exec" as NSString)
        },
    )
}

private struct ProcessOutput {
    let status: Int
    let stdout: String
    let stderr: String
}

private let searchPath = [Bundle.main.executableURL?.deletingLastPathComponent().path, loginPath].compactMap(\.self).joined(separator: ":")

private func runProcess(_ argv: [String]) -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["--"] + argv
    let output = Pipe()
    let errors = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return ProcessOutput(status: -1, stdout: "", stderr: "\(error)")
    }
    var errorData = Data()
    let reading = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: reading) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    reading.wait()
    process.waitUntilExit()
    return ProcessOutput(
        status: Int(process.terminationStatus),
        stdout: String(decoding: outputData, as: UTF8.self),
        stderr: String(decoding: errorData, as: UTF8.self),
    )
}

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
