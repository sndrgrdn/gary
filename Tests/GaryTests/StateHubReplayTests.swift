import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor
struct StateHubReplayTests {
    let topic = Topic.capability("battery")
    let target: Listener
    let other: Listener
    let hub = StateHub(sources: [:])

    init() throws {
        target = try Listener(SlotKey(id: #require(PluginID("you.power")), kind: .barWidget))
        other = try Listener(SlotKey(id: #require(PluginID("you.other")), kind: .barWidget))
        _ = hub.subscribe(target, to: [topic])
        _ = hub.subscribe(other, to: [topic])
    }

    func percent(_ value: Double) -> JSON {
        .object(["percent": .number(value)])
    }

    @Test func `a replay to one plugin leaves the others live and gives it the live value back at the end`() {
        hub.publish(topic, percent(80), Trace("test"))
        #expect(hub.beginReplay([topic], to: target.slot.id))
        hub.replay(topic, percent(15), Trace("replay"))
        hub.publish(topic, percent(79), Trace("test"))
        hub.endReplay()
        #expect(target.values == [percent(80), percent(15), percent(79)])
        #expect(other.values == [percent(80), percent(79)])
    }

    @Test func `a replay to every subscriber holds back live values until it ends`() {
        hub.publish(topic, percent(80), Trace("test"))
        #expect(hub.beginReplay([topic], to: nil))
        #expect(!hub.beginReplay([topic], to: nil))
        hub.publish(topic, percent(79), Trace("test"))
        hub.replay(topic, percent(15), Trace("replay"))
        hub.endReplay()
        hub.publish(topic, percent(15), Trace("test"))
        #expect(target.values == [percent(80), percent(15), percent(15)])
        #expect(other.values == target.values)
    }

    @Test func `a trace records each publish with its cause, subscribers and value`() throws {
        _ = TraceLog.poll(from: nil, values: true) { _ in [] }
        let trace = Trace("trace-test")
        hub.publish(topic, percent(42), trace)
        let events = TraceLog.poll(from: 0, values: true) { _ in [] }["events"]?.array ?? []
        let id = JSON.number(Double(trace.id))
        #expect(trace.id != 0)
        #expect(events.contains { $0["ev"] == .string("cause") && $0["trace"] == id && $0["cause"] == .string("trace-test") })
        let publish = try #require(events.first { $0["ev"] == .string("publish") && $0["trace"] == id })
        #expect(publish["subscribers"]?.array?.compactMap(\.string).sorted() == ["you.other/bar-widget", "you.power/bar-widget"])
        #expect(publish["value"] == percent(42))
        #expect(publish["bytes"] == .number(14))
    }
}
