import Foundation
import GaryCore
import GarySocket

private nonisolated(unsafe) var interrupted: sig_atomic_t = 0

func runTrace(_ arguments: [String]) -> Int32 {
    let usage = "usage: gary trace --record <seconds> | --follow [--topics <file>]\n"
    var rest = arguments[...]
    var seconds: Double?
    var follow = false
    var topicsPath: String?
    while let flag = rest.popFirst() {
        switch flag {
        case "--record": seconds = rest.popFirst().flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
            if seconds == nil {
                fputs(usage, stderr)
                return 64
            }
        case "--follow": follow = true
        case "--topics": topicsPath = rest.popFirst()
            if topicsPath == nil {
                fputs(usage, stderr)
                return 64
            }
        default:
            fputs(usage, stderr)
            return 64
        }
    }
    guard follow != (seconds != nil) else {
        fputs(usage, stderr)
        return 64
    }
    var topics: FileHandle?
    if let topicsPath {
        guard FileManager.default.createFile(atPath: topicsPath, contents: nil), let handle = FileHandle(forWritingAtPath: topicsPath) else {
            fputs("gary: cannot write \(topicsPath)\n", stderr)
            return 1
        }
        topics = handle
    }
    signal(SIGINT) { _ in interrupted = 1 }
    let values = topics != nil
    do {
        var cursor = try poll(.trace(from: nil, values: values), topics: topics)
        let end = seconds.map { Date().addingTimeInterval($0) }
        while interrupted == 0, end.map({ Date() < $0 }) ?? true {
            Thread.sleep(forTimeInterval: min(0.25, end.map { max(0, $0.timeIntervalSinceNow) } ?? 0.25))
            cursor = try poll(.trace(from: cursor, values: values), topics: topics)
        }
        try topics?.close()
        return 0
    } catch {
        fputs("gary: \(error)\n", stderr)
        return 1
    }
}

private struct TraceFailure: Error, CustomStringConvertible {
    let description: String
}

private func poll(_ request: Request, topics: FileHandle?) throws -> Int {
    let line = try requestLine(request.line, path: Paths.socket, timeout: request.timeout + 5)
    switch try Response.decode(line: line) {
    case let .failure(message): throw TraceFailure(description: message)
    case let .ok(text):
        let reply = try JSON.parse(text)
        if let dropped = reply["dropped"]?.number, dropped > 0 {
            print(JSON.object(["ev": .string("dropped"), "count": .number(dropped)]).text)
        }
        for event in reply["events"]?.array ?? [] {
            guard case var .object(fields) = event else { continue }
            if let value = fields.removeValue(forKey: "value"), let time = fields["t"], let topic = fields["topic"] {
                topics?.write(Data((JSON.object(["t": time, "topic": topic, "value": value]).text + "\n").utf8))
            }
            print(JSON.object(fields).text)
        }
        fflush(stdout)
        return Int(reply["next"]?.number ?? 0)
    }
}
