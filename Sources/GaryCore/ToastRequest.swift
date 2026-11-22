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

struct HostOptions {
    private let call: HostCall
    private let fields: [String: JSON]

    init(_ call: HostCall, keys: [String]) throws {
        guard let fields = call.arguments.first?.object else { throw call.fail("the argument must be an object") }
        if let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
            throw call.fail("unknown field \"\(unknown)\"; use " + keys.joined(separator: ", "))
        }
        self.call = call
        self.fields = fields
    }

    func string(_ key: String) throws -> String {
        guard let value = fields[key]?.string else { throw call.fail("\(key) must be a string") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = fields[key], value != .null else { return nil }
        guard let string = value.string else { throw call.fail("\(key) must be a string") }
        return string
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = fields[key], value != .null else { return nil }
        guard let number = value.number, number.isFinite else { throw call.fail("\(key) must be a number") }
        return number
    }
}
