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
        guard let record = try? PropertyListDecoder().decode(Record.self, from: record) else { return nil }
        self.init(
            id: id, app: record.app ?? appColumn, title: record.request.title, subtitle: record.request.subtitle,
            body: record.request.body, date: (record.date + Date.timeIntervalBetween1970AndReferenceDate) * 1000,
        )
    }
}

private struct Record: Decodable {
    let app: String?
    let request: RecordRequest
    let date: Double

    private enum CodingKeys: String, CodingKey {
        case app
        case request = "req"
        case date
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try? container.decodeIfPresent(String.self, forKey: .app)
        request = try container.decode(RecordRequest.self, forKey: .request)
        date = try container.decode(Double.self, forKey: .date)
    }
}

private struct RecordRequest: Decodable {
    let title: String?
    let subtitle: String?
    let body: String?

    private enum CodingKeys: String, CodingKey {
        case title = "titl"
        case subtitle = "subt"
        case body
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        body = try? container.decodeIfPresent(String.self, forKey: .body)
    }
}
