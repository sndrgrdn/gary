import Foundation
import GaryCore
import GarySocket

func runCli(_ verb: String, _ arguments: [String]) -> Int32 {
    var arguments = arguments
    if verb == "applyTheme", let path = arguments.first, !path.hasPrefix("{"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
        arguments[0] = text
    }
    let watch = verb == "stats" && arguments.contains("--watch")
    arguments.removeAll { watch && $0 == "--watch" }
    let request: Request
    do {
        request = try Request.parse(verb: verb, arguments: arguments)
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 64
    }
    var status = send(request)
    while watch, status == 0 {
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
        status = send(request)
    }
    return status
}

private func send(_ request: Request) -> Int32 {
    do {
        let line: String
        do {
            line = try requestLine(request.line, path: Paths.socket, timeout: request.timeout + 5)
        } catch SocketError.unreachable where request.verb == Request.permissions.verb || request == .summon(SurfaceAddress(.onboarding)) {
            try startApp()
            line = try requestLine(request.line, path: Paths.socket, timeout: request.timeout + 5)
        }
        switch try Response.decode(line: line) {
        case let .ok(result):
            if request == .quit {
                return awaitQuit("Gary stopped")
            }
            if !result.isEmpty {
                print(result)
            }
            return 0
        case let .failure(message):
            fputs("gary: \(message)\n", stderr)
            return 1
        }
    } catch where request == .quit {
        return awaitQuit("Gary is not running")
    } catch SocketError.unreachable {
        fputs("gary: not running (\(Paths.socket))\n", stderr)
        return 1
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 1
    }
}

private func awaitQuit(_ done: String) -> Int32 {
    for _ in 0..<50 {
        if !lockIsHeld(Paths.appLock), !lockIsHeld(Paths.supervisorLock) {
            print(done)
            return 0
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fputs("gary: Gary or its supervisor still runs after 5 seconds\n", stderr)
    return 1
}

private func startApp() throws {
    guard Bundle.main.bundleIdentifier != nil, !Paths.isolated else { throw SocketError.unreachable(Paths.socket) }
    fputs("gary: starting \(Bundle.main.bundlePath)\n", stderr)
    let open = try Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-g", Bundle.main.bundlePath])
    open.waitUntilExit()
    for _ in 0..<50 {
        if (try? requestLine(Request.ping.line, path: Paths.socket, timeout: 1)) != nil {
            return
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw SocketError.unreachable(Paths.socket)
}

let appUsage: [CommandUsage] = [
    CommandUsage("app", "Run the shell in the foreground, logging to the terminal, without the crash supervisor.", nil),
    CommandUsage("login [on|off|status]", "Start Gary at login, or stop doing so.", nil),
    CommandUsage("--version", "Print the version of this Gary.", nil),
    CommandUsage("update", "Install the latest release from GitHub, after saying which version is installed and which is the latest.", nil),
    CommandUsage(
        "report",
        "Print a bug report in Markdown: the versions, gary doctor, gary listPlugins, gary stats, the last 100 log lines, and recent crash reports.",
        nil,
    ),
]

func runUpdate(_ arguments: [String]) -> Int32 {
    guard arguments.isEmpty else {
        fputs("usage: gary update\n", stderr)
        return 64
    }
    guard let script = Bundle.main.path(forResource: "install", ofType: "sh") else {
        fputs("gary: update needs the app bundle; run the gary inside Gary.app\n", stderr)
        return 1
    }
    do {
        let install = try Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: [script])
        install.waitUntilExit()
        return install.terminationStatus
    } catch {
        fputs("gary: update: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

func runHelp() -> Int32 {
    print("usage: gary <verb> [args], sent to the running app over \(Paths.socket)\n")
    for usage in Request.usage {
        printUsage(usage)
    }
    print("\nThese commands work without the running app:\n")
    for usage in appUsage + skillUsage + pluginUsage {
        printUsage(usage)
    }
    return 0
}

private func printUsage(_ usage: CommandUsage) {
    print("  \(usage.syntax)\n      \(usage.description)" + (usage.example.map { "\n      for example: \($0)" } ?? ""))
}
