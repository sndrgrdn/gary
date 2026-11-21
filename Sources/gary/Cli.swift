import Foundation
import GaryCore
import GarySocket

let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("gary.sock")

func runCli(_ verb: String, _ arguments: [String]) -> Int32 {
    var arguments = arguments
    if verb == "applyTheme", let path = arguments.first, !path.hasPrefix("{"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
        arguments[0] = text
    }
    let request: Request
    do {
        request = try Request.parse(verb: verb, arguments: arguments)
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 64
    }
    do {
        let line: String
        do {
            line = try requestLine(request.line, path: socketPath, timeout: 10)
        } catch SocketError.unreachable where request.verb == Request.permissions.verb {
            try startApp()
            line = try requestLine(request.line, path: socketPath, timeout: 10)
        }
        switch try Response.decode(line: line) {
        case .ok(let result):
            if request == .quit { return awaitQuit("Gary stopped") }
            if !result.isEmpty { print(result) }
            return 0
        case .failure(let message):
            fputs("gary: \(message)\n", stderr)
            return 1
        }
    } catch where request == .quit {
        return awaitQuit("Gary is not running")
    } catch SocketError.unreachable {
        fputs("gary: not running (\(socketPath))\n", stderr)
        return 1
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 1
    }
}

private func awaitQuit(_ done: String) -> Int32 {
    for _ in 0..<50 {
        if !lockIsHeld(appLockPath) && !lockIsHeld(supervisorLockPath) {
            print(done)
            return 0
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fputs("gary: Gary or its supervisor still runs after 5 seconds\n", stderr)
    return 1
}

private func startApp() throws {
    guard Bundle.main.bundleIdentifier != nil else { throw SocketError.unreachable(socketPath) }
    fputs("gary: starting \(Bundle.main.bundlePath)\n", stderr)
    let open = try Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-g", Bundle.main.bundlePath])
    open.waitUntilExit()
    for _ in 0..<50 {
        if (try? requestLine(Request.ping.line, path: socketPath, timeout: 1)) != nil { return }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw SocketError.unreachable(socketPath)
}

let appUsage: [(syntax: String, description: String)] = [
    ("app", "Run the shell in the foreground, logging to the terminal, without the crash supervisor."),
    ("login [on|off|status]", "Start Gary at login, or stop doing so."),
]

func runHelp() -> Int32 {
    print("usage: gary <verb> [args], sent to the running app over \(socketPath)\n")
    for (syntax, description) in Request.usage { print("  \(syntax)\n      \(description)") }
    print("\nThese commands work without the running app:\n")
    for (syntax, description) in appUsage + skillUsage + pluginUsage { print("  \(syntax)\n      \(description)") }
    return 0
}
