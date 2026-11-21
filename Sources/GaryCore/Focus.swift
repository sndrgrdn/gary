import Foundation

public struct FocusState: Equatable, Sendable {
    public enum Source: String, Sendable {
        case manual, schedule
    }

    public let mode: String
    public let name: String?
    public let symbol: String?
    public let source: Source

    public struct FileError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func resolve(assertions: Data, configurations: Data, at date: Date, calendar: Calendar) throws -> FocusState? {
        guard let records = try? JSON.parse(assertions)["data"]?.array?.first, records.object != nil else {
            throw FileError(description: "Assertions.json has no data record")
        }
        guard let modes = try? JSON.parse(configurations)["data"]?.array?.first?["modeConfigurations"]?.object else {
            throw FileError(description: "ModeConfigurations.json has no modeConfigurations")
        }
        func state(_ mode: String, _ source: Source) -> FocusState {
            let details = modes[mode]?["mode"]
            return FocusState(mode: mode, name: details?["name"]?.string, symbol: details?["symbolImageName"]?.string, source: source)
        }
        let manual = (records["storeAssertionRecords"]?.array ?? [])
            .compactMap { record -> (start: Double, mode: String)? in
                guard let mode = record["assertionDetails"]?["assertionDetailsModeIdentifier"]?.string else { return nil }
                return (record["assertionStartDateTimestamp"]?.number ?? 0, mode)
            }
            .max { $0.start < $1.start }
        if let manual { return state(manual.mode, .manual) }
        for (mode, configuration) in modes.sorted(by: { $0.key < $1.key }) {
            let triggers = configuration["triggers"]?["triggers"]?.array ?? []
            if triggers.contains(where: { Schedule($0)?.covers(date, calendar: calendar) == true }) { return state(mode, .schedule) }
        }
        return nil
    }
}

struct Schedule {
    let start: Int
    let end: Int
    let weekdays: Int

    init?(_ trigger: JSON) {
        guard trigger["class"]?.string == "DNDModeConfigurationScheduleTrigger", trigger["enabledSetting"]?.number == 2,
              let startHour = trigger["timePeriodStartTimeHour"]?.number, let startMinute = trigger["timePeriodStartTimeMinute"]?.number,
              let endHour = trigger["timePeriodEndTimeHour"]?.number, let endMinute = trigger["timePeriodEndTimeMinute"]?.number,
              let weekdays = trigger["timePeriodWeekdays"]?.number else { return nil }
        start = Int(startHour) * 60 + Int(startMinute)
        end = Int(endHour) * 60 + Int(endMinute)
        self.weekdays = Int(weekdays)
    }

    func covers(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = parts.hour! * 60 + parts.minute!
        let today = parts.weekday! - 1, yesterday = (today + 6) % 7
        func on(_ day: Int) -> Bool { weekdays & (1 << day) != 0 }
        if start == end { return on(today) }
        if start < end { return on(today) && minute >= start && minute < end }
        return (on(today) && minute >= start) || (on(yesterday) && minute < end)
    }
}
