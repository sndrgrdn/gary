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
        switch try Response.decode(line: try requestLine(request.line, path: socketPath, timeout: 10)) {
        case .ok(let result):
            if !result.isEmpty { print(result) }
            return 0
        case .failure(let message):
            fputs("gary: \(message)\n", stderr)
            return 1
        }
    } catch SocketError.unreachable {
        fputs("gary: not running (\(socketPath))\n", stderr)
        return 1
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 1
    }
}

func runHelp() -> Int32 {
    print("usage: gary <verb> [args], sent to the running app over \(socketPath)\n")
    for (syntax, description) in Request.usage { print("  \(syntax)\n      \(description)") }
    print("\n  app\n      Run the shell in the foreground, logging to the terminal.")
    print("\nPlugin commands work on ~/.config/gary without the running app:\n")
    for (syntax, description) in pluginUsage { print("  \(syntax)\n      \(description)") }
    return 0
}
