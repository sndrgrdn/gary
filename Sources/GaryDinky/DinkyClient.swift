import Foundation
import GarySocket

public enum DinkyError: Error, Equatable, CustomStringConvertible {
    case failed(String)
    case malformedReply(String)

    public var description: String {
        switch self {
        case .failed(let message): return "dinky: \(message)"
        case .malformedReply(let reply): return "dinky sent an unexpected reply \"\(reply.prefix(80))\""
        }
    }
}

public struct DinkyClient: Sendable {
    public static let defaultPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("dinky.sock")

    public let path: String
    public let timeout: TimeInterval

    public init(path: String = defaultPath, timeout: TimeInterval = 2) {
        self.path = path
        self.timeout = timeout
    }

    public func run(_ command: String) throws -> String {
        try Self.parseReply(try exchange(command, path: path, timeout: timeout))
    }

    public static func parseReply(_ reply: String) throws -> String {
        if reply == "ok" || reply.hasPrefix("ok\n") { return String(reply.dropFirst(3)) }
        if reply == "error" || reply.hasPrefix("error\n") { throw DinkyError.failed(String(reply.dropFirst(6))) }
        throw DinkyError.malformedReply(reply)
    }
}
