import Foundation

public struct ToastRequest: Equatable, Sendable {
    public static let defaultTimeout = 5.0

    public enum Icon: Equatable, Sendable {
        case symbol(String)
        case glyph(String, font: String?)
    }

    public let title: String
    public let body: String?
    public let icon: Icon?
    public let timeout: TimeInterval?

    public init(title: String, body: String? = nil, icon: Icon? = nil, timeout: TimeInterval? = defaultTimeout) {
        self.title = title
        self.body = body
        self.icon = icon
        self.timeout = timeout
    }

    public static func parse(_ call: HostCall) throws -> ToastRequest {
        let options = try HostOptions(call, keys: ["title", "body", "icon", "glyph", "font", "timeout"])
        let timeout = try options.optionalNumber("timeout") ?? defaultTimeout
        guard timeout >= 0 else { throw call.fail("timeout must be 0 or more seconds") }
        let icon: Icon?
        switch try (options.optionalString("icon"), options.optionalString("glyph"), options.optionalString("font")) {
        case (_?, _?, _): throw call.fail("set icon or glyph, not both")
        case (_, nil, _?): throw call.fail("font needs a glyph")
        case let (symbol?, nil, nil): icon = .symbol(symbol)
        case let (nil, glyph?, font): icon = .glyph(glyph, font: font)
        case (nil, nil, nil): icon = nil
        }
        return try ToastRequest(
            title: options.string("title"),
            body: options.optionalString("body"),
            icon: icon,
            timeout: timeout == 0 ? nil : timeout,
        )
    }
}
