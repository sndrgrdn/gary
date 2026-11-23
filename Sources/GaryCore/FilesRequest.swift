import Foundation

public enum FilesRequest: Equatable, Sendable {
    case read(path: String)
    case write(path: String, text: String)
    case makeDirectory(path: String)
    case remove(path: String)
    case list(path: String)

    public static let methods = ["readFile", "writeFile", "mkdir", "remove", "list"]

    public static func parse(_ call: HostCall, home: String, folder: String) throws -> FilesRequest {
        guard methods.contains(call.method) else { throw call.unknownMethod }
        let path = try call.path(0, home: home, folder: folder)
        switch call.method {
        case "readFile": return .read(path: path)
        case "writeFile": return try .write(path: path, text: call.string(1, "text"))
        case "mkdir": return .makeDirectory(path: path)
        case "list": return .list(path: path)
        case "remove":
            guard path != "/", path != home, path != folder else { throw call.fail("refusing to remove \(path)") }
            return .remove(path: path)
        default: throw call.unknownMethod
        }
    }
}
