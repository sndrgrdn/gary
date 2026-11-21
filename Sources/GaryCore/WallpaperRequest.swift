import Foundation

public enum WallpaperRequest: Equatable, Sendable {
    case get
    case set(path: String, display: String?)

    public static let methods = ["get", "set"]

    public static func parse(_ call: HostCall, home: String) throws -> WallpaperRequest {
        switch call.method {
        case "get": .get
        case "set": try .set(path: call.path(0, home: home), display: call.optionalString(1, "display"))
        default: throw call.unknownMethod
        }
    }
}
