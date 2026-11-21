import Foundation

public struct DeliveredNotification: Equatable, Sendable {
    public let id: Int
    public let app: String
    public let title: String?
    public let subtitle: String?
    public let body: String?
    public let date: Double

    public init(id: Int, app: String, title: String?, subtitle: String?, body: String?, date: Double) {
        self.id = id
        self.app = app
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
    }

    public init?(id: Int, appColumn: String, record: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any], let date = plist["date"] as? Double else { return nil }
        self.init(
            id: id, app: plist["app"] as? String ?? appColumn, title: request["titl"] as? String, subtitle: request["subt"] as? String,
            body: request["body"] as? String, date: (date + Date.timeIntervalBetween1970AndReferenceDate) * 1000
        )
    }
}
