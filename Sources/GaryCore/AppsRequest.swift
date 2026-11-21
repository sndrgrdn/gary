import Foundation

public enum AppsRequest: Equatable, Sendable {
    case launch(bundle: String)
    case activate(bundle: String)
    case quit(bundle: String)

    public static let methods = ["launch", "activate", "quit"]

    public static func parse(_ call: HostCall) throws -> AppsRequest {
        let make: (String) -> AppsRequest
        switch call.method {
        case "launch": make = { .launch(bundle: $0) }
        case "activate": make = { .activate(bundle: $0) }
        case "quit": make = { .quit(bundle: $0) }
        default: throw call.unknownMethod
        }
        let bundle = try call.string(0, "bundle id")
        guard !bundle.isEmpty, bundle.count <= 255, bundle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw call.fail("bundle id \"\(bundle)\" must be letters, digits, dots and hyphens")
        }
        return make(bundle)
    }
}
