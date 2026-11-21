import Foundation

public protocol Snapshot: Equatable, Sendable {
    static var topic: Topic { get }
    var json: JSON { get }
}

public struct BatterySnapshot: Snapshot {
    public enum PowerSource: String, Sendable {
        case battery, ac
    }

    public static let topic = Topic.battery
    public var percent: Int?
    public var charging: Bool
    public var source: PowerSource

    public init(percent: Int?, charging: Bool, source: PowerSource) {
        self.percent = percent
        self.charging = charging
        self.source = source
    }

    public var json: JSON {
        .object([
            "present": .bool(percent != nil),
            "percent": percent.map { .number(Double($0)) } ?? .null,
            "charging": .bool(charging),
            "source": .string(source.rawValue),
        ])
    }
}

public struct ClockSnapshot: Snapshot {
    public static let topic = Topic.clock
    public var epochMilliseconds: Double

    public init(epochMilliseconds: Double) {
        self.epochMilliseconds = epochMilliseconds
    }

    public var json: JSON { .object(["epoch": .number(epochMilliseconds)]) }
}
