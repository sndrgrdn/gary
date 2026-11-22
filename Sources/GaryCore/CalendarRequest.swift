import Foundation

public enum CalendarRequest: Equatable, Sendable {
    case calendars
    case events(start: Date, end: Date)

    public static let methods = ["calendars", "events"]

    public static func parse(_ call: HostCall) throws -> CalendarRequest {
        switch call.method {
        case "calendars":
            return .calendars
        case "events":
            let start = try call.number(0, "start")
            let end = try call.number(1, "end")
            guard end > start else { throw call.fail("end must be after start") }
            return .events(start: Date(timeIntervalSince1970: start / 1000), end: Date(timeIntervalSince1970: end / 1000))
        default:
            throw call.unknownMethod
        }
    }
}
