import Foundation

public enum AppTarget: Equatable, Sendable, CustomStringConvertible {
    case bundle(String)
    case path(String)

    static func parse(_ call: HostCall, home: String) throws -> AppTarget {
        let raw = try call.string(0, "app")
        if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            guard let path = absolutePath(raw, home: home, folder: home), path.hasSuffix(".app") else {
                throw call.fail("path \"\(raw)\" must end in .app")
            }
            return .path(path)
        }
        guard !raw.isEmpty, raw.count <= 255, raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw call.fail("app \"\(raw)\" must be a bundle id of letters, digits, dots and hyphens, or an absolute .app path")
        }
        return .bundle(raw)
    }

    public var description: String {
        switch self {
        case let .bundle(id): id
        case let .path(path): path
        }
    }
}

public enum AppsRequest: Equatable, Sendable {
    case installed
    case launch(AppTarget)
    case activate(AppTarget)
    case quit(AppTarget)

    public static let methods = ["installed", "launch", "activate", "quit"]

    public static func parse(_ call: HostCall, home: String) throws -> AppsRequest {
        switch call.method {
        case "installed": .installed
        case "launch": try .launch(AppTarget.parse(call, home: home))
        case "activate": try .activate(AppTarget.parse(call, home: home))
        case "quit": try .quit(AppTarget.parse(call, home: home))
        default: throw call.unknownMethod
        }
    }
}
