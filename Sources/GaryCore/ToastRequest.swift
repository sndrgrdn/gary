import Foundation

public struct ToastRequest: Equatable, Sendable {
    public static let defaultTimeout = 5.0

    public let title: String
    public let body: String?
    public let icon: String?
    public let timeout: TimeInterval?

    public init(title: String, body: String? = nil, icon: String? = nil, timeout: TimeInterval? = defaultTimeout) {
        self.title = title
        self.body = body
        self.icon = icon
        self.timeout = timeout
    }

    public static func parse(_ call: HostCall) throws -> ToastRequest {
        let options = try HostOptions(call, keys: ["title", "body", "icon", "timeout"])
        let timeout = try options.optionalNumber("timeout") ?? defaultTimeout
        guard timeout >= 0 else { throw call.fail("timeout must be 0 or more seconds") }
        return try ToastRequest(
            title: options.string("title"),
            body: options.optionalString("body"),
            icon: options.optionalString("icon"),
            timeout: timeout == 0 ? nil : timeout,
        )
    }
}
