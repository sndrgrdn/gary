import Foundation
import GaryCore
import JavaScriptCore

extension Capability {
    static let exec = Capability(name: "exec", summary: "Run a command off the main thread and get its exit status and output.", types: """
    declare namespace Gary {
      interface Host { exec(argv: string[], callback: (result: ExecResult) => void): void }
      interface ExecResult { status: number; stdout: string; stderr: string }
    }
    """, install: { host, plugin in
        let exec: @convention(block) (JSValue, JSValue) -> Void = { [weak plugin] argv, callback in
            guard let argv = argv.toArray() as? [String], !argv.isEmpty, callback.isObject else {
                let context = JSContext.current()!
                context.exception = JSValue(newErrorFromMessage: "host.exec takes an array of strings and a callback", in: context)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runProcess(argv)
                plugin?.queue.async { plugin?.callBack(callback, [result], Trace("exec")) }
            }
        }
        host.setObject(exec, forKeyedSubscript: "exec" as NSString)
    })
}

private func runProcess(_ argv: [String]) -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["--"] + argv
    let output = Pipe(), errors = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = [Bundle.main.executableURL!.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return ["status": -1, "stdout": "", "stderr": "\(error)"]
    }
    var errorData = Data()
    let reading = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: reading) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    reading.wait()
    process.waitUntilExit()
    return [
        "status": Int(process.terminationStatus),
        "stdout": String(decoding: outputData, as: UTF8.self),
        "stderr": String(decoding: errorData, as: UTF8.self),
    ]
}
