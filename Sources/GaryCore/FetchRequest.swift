import Foundation

public struct FetchRequest: Equatable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: String?

    private static let keys = ["method", "headers", "body"]

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    public static func parse(_ arguments: [JSON]) throws -> FetchRequest {
        guard let address = arguments.first?.string, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased())
        else { throw ArgumentError("fetch takes an http or https URL") }
        guard let options = arguments.dropFirst().first, options != .null else { return FetchRequest(url: url) }
        guard let fields = options.object else { throw ArgumentError("fetch: options must be an object") }
        if let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
            throw ArgumentError("fetch: unknown option \"\(unknown)\"; use " + keys.joined(separator: ", "))
        }
        return try FetchRequest(url: url, method: method(fields["method"]), headers: headers(fields["headers"]), body: body(fields["body"]))
    }

    private static func method(_ value: JSON?) throws -> String {
        guard let value, value != .null else { return "GET" }
        guard let method = value.string, !method.isEmpty else { throw ArgumentError("fetch: method must be a string") }
        return method.uppercased()
    }

    private static func headers(_ value: JSON?) throws -> [String: String] {
        guard let value, value != .null else { return [:] }
        guard let fields = value.object else { throw ArgumentError("fetch: headers must be an object of strings") }
        return try fields.mapValues { header in
            guard let text = header.string else { throw ArgumentError("fetch: headers must be an object of strings") }
            return text
        }
    }

    private static func body(_ value: JSON?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.string else { throw ArgumentError("fetch: body must be a string") }
        return text
    }
}
