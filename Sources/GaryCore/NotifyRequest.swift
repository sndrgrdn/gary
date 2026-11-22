import Foundation

public struct NotifyRequest: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let body: String?
    public let sound: Bool

    public static let methods = ["post"]

    public init(title: String, subtitle: String? = nil, body: String? = nil, sound: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
    }

    public static func parse(_ call: HostCall) throws -> NotifyRequest {
        guard call.method == "post" else { throw call.unknownMethod }
        let options = try HostOptions(call, keys: ["title", "subtitle", "body", "sound"])
        return try NotifyRequest(
            title: options.string("title"),
            subtitle: options.optionalString("subtitle"),
            body: options.optionalString("body"),
            sound: options.optionalBool("sound") ?? false,
        )
    }
}
