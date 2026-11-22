import Foundation

public enum ImageSource: Equatable, Sendable {
    case file(String)
    case screen(ScreenArea)
}

public enum VisionRequest: Equatable, Sendable {
    case readText(ImageSource)

    public static let methods = ["readText"]

    public static func parse(_ call: HostCall, home: String, folder: String) throws -> VisionRequest {
        guard call.method == "readText" else { throw call.unknownMethod }
        guard case let .string(raw)? = call.arguments.first else { return try .readText(.screen(ScreenArea.parse(call.arguments.first, call))) }
        guard let path = absolutePath(raw, home: home, folder: folder) else {
            throw call.fail("path \"\(raw)\" must be absolute, start with ~/, or be relative to the plugin folder")
        }
        return .readText(.file(path))
    }
}
