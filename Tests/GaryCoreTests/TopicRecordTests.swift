import GaryCore
import Testing

struct TopicRecordTests {
    @Test func `records parse in time order and name capability and plugin topics`() throws {
        let records = try TopicRecord.parse(lines: """
        {"t":12.5,"topic":"you.weather","value":{"temp":3}}

        {"t":10,"topic":"battery","value":{"percent":15,"charging":false}}
        """)
        #expect(try records == [
            TopicRecord(time: 10, topic: .capability("battery"), value: .object(["percent": .number(15), "charging": .bool(false)])),
            TopicRecord(time: 12.5, topic: .plugin(#require(PluginID("you.weather"))), value: .object(["temp": .number(3)])),
        ])
        #expect(records.map { TopicRecord($0.json) } == records)
    }
}
