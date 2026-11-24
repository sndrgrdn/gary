import Foundation

public struct TopicRecord: Equatable, Sendable {
    public let time: Double
    public let topic: Topic
    public let value: JSON

    public init(time: Double, topic: Topic, value: JSON) {
        self.time = time
        self.topic = topic
        self.value = value
    }

    public init?(_ json: JSON) {
        guard let time = json["t"]?.number, let name = json["topic"]?.string, !name.isEmpty, let value = json["value"] else { return nil }
        self.init(time: time, topic: PluginID(name).map(Topic.plugin) ?? .capability(name), value: value)
    }

    public var json: JSON {
        .object(["t": .number(time), "topic": .string(topic.description), "value": value])
    }

    public static func parse(lines text: String) throws -> [TopicRecord] {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let records = try lines.enumerated().map { index, line in
            guard let json = try? JSON.parse(String(line)), let record = TopicRecord(json) else {
                throw RequestError(description: "line \(index + 1) is not a JSON object with a number t, a string topic and a value")
            }
            return record
        }
        guard !records.isEmpty else { throw RequestError(description: "no topic values to replay") }
        return records.sorted { $0.time < $1.time }
    }
}
