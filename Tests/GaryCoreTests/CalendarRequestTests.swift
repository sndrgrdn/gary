import Foundation
@testable import GaryCore
import Testing

struct CalendarRequestTests {
    private func call(_ method: String, _ arguments: JSON...) -> HostCall {
        HostCall(api: "calendar", method: method, arguments: arguments)
    }

    @Test func `events takes A range in milliseconds since 1970`() throws {
        #expect(try CalendarRequest.parse(call("events", .number(1_800_000_000_000), .number(1_800_086_400_000))) == .events(
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_086_400),
        ))
        #expect(try CalendarRequest.parse(call("calendars")) == .calendars)
    }

    @Test func `events rejects an empty or reversed range and missing numbers`() {
        #expect(throws: ArgumentError("host.calendar.events: end must be after start")) {
            try CalendarRequest.parse(call("events", .number(5), .number(5)))
        }
        #expect(throws: ArgumentError("host.calendar.events: end must be a number")) {
            try CalendarRequest.parse(call("events", .number(5)))
        }
        #expect(throws: ArgumentError("host.calendar.reminders is not a method")) { try CalendarRequest.parse(call("reminders")) }
    }
}
