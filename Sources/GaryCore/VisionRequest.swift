import Foundation

public enum ImageSource: Equatable, Sendable {
    case file(String)
    case screen(ScreenArea)
}

public enum VisionRequest: Equatable, Sendable {
    case readText(ImageSource)
    case readCodes(ImageSource)

    public static let methods = ["readText", "readCodes"]

    public static func parse(_ call: HostCall, home: String, folder: String) throws -> VisionRequest {
        switch call.method {
        case "readText": try .readText(source(call, home: home, folder: folder))
        case "readCodes": try .readCodes(source(call, home: home, folder: folder))
        default: throw call.unknownMethod
        }
    }

    private static func source(_ call: HostCall, home: String, folder: String) throws -> ImageSource {
        guard case let .string(raw)? = call.arguments.first else { return try .screen(ScreenArea.parse(call.arguments.first, call)) }
        guard let path = absolutePath(raw, home: home, folder: folder) else {
            throw call.fail("path \"\(raw)\" must be absolute, start with ~/, or be relative to the plugin folder")
        }
        return .file(path)
    }
}
