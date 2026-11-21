import Foundation
import Testing
@testable import GaryCore

struct FocusTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    static func assertions(_ modes: [(String, Double)]) -> Data {
        let records = modes.map { mode, start in
            #"{"assertionUUID":"A","assertionStartDateTimestamp":\#(start),"assertionDetails":{"assertionDetailsIdentifier":"com.apple.donotdisturb.private.intents","assertionDetailsModeIdentifier":"\#(mode)"}}"#
        }
        return Data(#"{"data":[{"storeAssertionRecords":[\#(records.joined(separator: ","))],"storeInvalidationRecords":[]}],"header":{"version":8}}"#.utf8)
    }

    static let noAssertions = Data(#"{"data":[{"storeInvalidationRecords":[]}],"header":{"version":8}}"#.utf8)

    static func configurations(_ triggers: String = "") -> Data {
        Data(#"""
        {"data":[{"modeConfigurations":{
          "com.apple.focus.work":{"mode":{"name":"Work","symbolImageName":"person.lanyardcard.fill","modeIdentifier":"com.apple.focus.work"},"triggers":{"triggers":[]}},
          "com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb","symbolImageName":"moon.fill","modeIdentifier":"com.apple.donotdisturb.mode.default"},"triggers":{"triggers":[\#(triggers)]}}
        }}]}
        """#.utf8)
    }

    static func schedule(_ start: Int, _ end: Int, weekdays: Int = 127, enabled: Int = 2) -> String {
        #"{"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":\#(enabled),"timePeriodStartTimeHour":\#(start),"timePeriodStartTimeMinute":0,"timePeriodEndTimeHour":\#(end),"timePeriodEndTimeMinute":0,"timePeriodWeekdays":\#(weekdays)}"#
    }

    func resolve(_ assertions: Data, _ configurations: Data, _ date: Date) throws -> FocusState? {
        try FocusState.resolve(assertions: assertions, configurations: configurations, at: date, calendar: Self.calendar)
    }

    @Test func aManuallyEnabledFocusIsActiveWithItsNameAndSymbol() throws {
        let state = try resolve(Self.assertions([("com.apple.donotdisturb.mode.default", 100), ("com.apple.focus.work", 200)]), Self.configurations(), Self.at(21, 12))
        #expect(state == FocusState(mode: "com.apple.focus.work", name: "Work", symbol: "person.lanyardcard.fill", source: .manual))
    }

    @Test func noAssertionAndNoScheduleMeansNoFocus() throws {
        #expect(try resolve(Self.noAssertions, Self.configurations(), Self.at(21, 12)) == nil)
    }

    @Test func anOvernightScheduleCoversLateEveningAndEarlyMorningOnly() throws {
        let configurations = Self.configurations(Self.schedule(22, 10))
        #expect(try resolve(Self.noAssertions, configurations, Self.at(21, 23))?.source == .schedule)
        #expect(try resolve(Self.noAssertions, configurations, Self.at(21, 9, 59))?.name == "Do Not Disturb")
        #expect(try resolve(Self.noAssertions, configurations, Self.at(21, 10)) == nil)
        #expect(try resolve(Self.noAssertions, configurations, Self.at(21, 12)) == nil)
    }

    @Test func aDisabledScheduleNeverActivates() throws {
        let configurations = Self.configurations(Self.schedule(0, 0, enabled: 1))
        #expect(try resolve(Self.noAssertions, configurations, Self.at(21, 12)) == nil)
    }

    @Test func weekdayBitsStartWithSundayAndAnOvernightWindowBelongsToTheDayItStarted() throws {
        let workdays = Self.configurations(Self.schedule(9, 17, weekdays: 0b0111110))
        #expect(try resolve(Self.noAssertions, workdays, Self.at(21, 10)) == nil)
        #expect(try resolve(Self.noAssertions, workdays, Self.at(23, 10)) != nil)
        let fridayNight = Self.configurations(Self.schedule(22, 6, weekdays: 1 << 5))
        #expect(try resolve(Self.noAssertions, fridayNight, Self.at(21, 1)) != nil)
        #expect(try resolve(Self.noAssertions, fridayNight, Self.at(21, 23)) == nil)
    }

    @Test func aManualFocusWinsOverASchedule() throws {
        let state = try resolve(Self.assertions([("com.apple.focus.work", 1)]), Self.configurations(Self.schedule(0, 0)), Self.at(21, 12))
        #expect(state?.mode == "com.apple.focus.work")
    }

    @Test func unreadableFilesAreErrors() {
        #expect(throws: FocusState.FileError.self) { try resolve(Data("{}".utf8), Self.configurations(), Self.at(21, 12)) }
        #expect(throws: FocusState.FileError.self) { try resolve(Self.noAssertions, Data("not json".utf8), Self.at(21, 12)) }
    }
}
