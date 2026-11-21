import Foundation

public enum FilesRequest: Equatable, Sendable {
    case read(path: String)
    case write(path: String, text: String)
    case makeDirectory(path: String)
    case remove(path: String)
    case list(path: String)

    public static let methods = ["readFile", "writeFile", "mkdir", "remove", "list"]

    public static func parse(_ call: HostCall, home: String) throws -> FilesRequest {
        guard methods.contains(call.method) else { throw call.unknownMethod }
        let path = try call.path(0, home: home)
        switch call.method {
        case "readFile": return .read(path: path)
        case "writeFile": return .write(path: path, text: try call.string(1, "text"))
        case "mkdir": return .makeDirectory(path: path)
        case "list": return .list(path: path)
        default:
            guard path != "/" && path != home else { throw call.fail("refusing to remove \(path)") }
            return .remove(path: path)
        }
    }
}
