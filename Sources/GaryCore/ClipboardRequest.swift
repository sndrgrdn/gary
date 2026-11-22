import Foundation

public enum ClipboardContent: Equatable, Sendable {
    case text(String, concealed: Bool)
    case image(path: String)
    case files(paths: [String])
}

public enum ClipboardRequest: Equatable, Sendable {
    case read
    case write(ClipboardContent)

    public static let methods = ["read", "writeText", "writeImage", "writeFiles"]

    public static func parse(_ call: HostCall, home: String, folder: String) throws -> ClipboardRequest {
        switch call.method {
        case "read": return .read
        case "writeText": return try .write(.text(call.string(0, "text"), concealed: call.optionalBool(1, "concealed") ?? false))
        case "writeImage": return try .write(.image(path: call.path(0, home: home, folder: folder)))
        case "writeFiles":
            let raw = try call.strings(0, "paths")
            let paths = raw.compactMap { absolutePath($0, home: home, folder: folder) }
            guard !raw.isEmpty, paths.count == raw.count else {
                throw call.fail("paths must be one or more paths that are absolute, start with ~/, or are relative to the plugin folder")
            }
            return .write(.files(paths: paths))
        default: throw call.unknownMethod
        }
    }
}
