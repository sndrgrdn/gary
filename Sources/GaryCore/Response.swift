import Foundation

public enum Response: Equatable, Sendable {
    case ok(String)
    case failure(String)

    public var line: String {
        switch self {
        case let .ok(result): JSON.object(["ok": .bool(true), "result": .string(result)]).text
        case let .failure(message): JSON.object(["ok": .bool(false), "error": .string(message)]).text
        }
    }

    public static func decode(line: String) throws -> Response {
        let json = try? JSON.parse(line)
        switch (json?["ok"]?.bool, json?["result"]?.string, json?["error"]?.string) {
        case (true?, let result?, _): return .ok(result)
        case (false?, _, let message?): return .failure(message)
        default: throw RequestError(description: "malformed response \(line.prefix(200))")
        }
    }
}
