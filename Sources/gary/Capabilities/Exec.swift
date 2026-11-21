import Foundation
import GaryCore
import JavaScriptCore

extension PluginRuntime {
    func installExec(on host: JSValue) {
        let execBlock: @convention(block) (JSValue, JSValue) -> Void = { [weak self] argv, callback in
            guard let argv = argv.toArray() as? [String], !argv.isEmpty, callback.isObject else {
                let context = JSContext.current()!
                context.exception = JSValue(newErrorFromMessage: "host.exec takes an array of strings and a callback", in: context)
                return
            }
            self?.exec(argv, callback)
        }
        host.setObject(execBlock, forKeyedSubscript: "exec" as NSString)
    }

    private func exec(_ argv: [String], _ callback: JSValue) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runProcess(argv)
            self?.queue.async { [weak self] in
                guard let self, functions != nil else { return }
                callBack(callback, [result], Trace("exec"))
            }
        }
    }
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
