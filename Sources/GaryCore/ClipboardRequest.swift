import Foundation

public enum ClipboardRequest: Equatable, Sendable {
    case read
    case writeText(String)

    public static let methods = ["read", "writeText"]

    public static func parse(_ call: HostCall) throws -> ClipboardRequest {
        switch call.method {
        case "read": return .read
        case "writeText": return .writeText(try call.string(0, "text"))
        default: throw call.unknownMethod
        }
    }
}
