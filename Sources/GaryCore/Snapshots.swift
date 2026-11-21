import Foundation

/// Immutable host state a plugin receives as `state[topic]` in `render(state)`.
public protocol Snapshot: Equatable, Sendable {
    static var topic: Topic { get }
    var json: JSON { get }
}

public struct Workspace: Equatable, Sendable {
    public var name: String
    /// The current Space of its display.
    public var visible: Bool
    /// Visible on the display that has focus.
    public var focused: Bool

    public init(name: String, visible: Bool, focused: Bool) {
        self.name = name
        self.visible = visible
        self.focused = focused
    }
}

public struct DisplayWorkspaces: Equatable, Sendable {
    public var display: String
    public var workspaces: [Workspace]

    public init(display: String, workspaces: [Workspace]) {
        self.display = display
        self.workspaces = workspaces
    }
}

public struct WorkspacesSnapshot: Snapshot {
    public enum Source: String, Sendable {
        case dinky, native
    }

    public static let topic = Topic.workspaces
    public var source: Source
    public var displays: [DisplayWorkspaces]

    public init(source: Source, displays: [DisplayWorkspaces]) {
        self.source = source
        self.displays = displays
    }

    public var json: JSON {
        .object([
            "source": .string(source.rawValue),
            "displays": .array(displays.map { display in
                .object([
                    "id": .string(display.display),
                    "workspaces": .array(display.workspaces.map { workspace in
                        .object(["name": .string(workspace.name), "visible": .bool(workspace.visible), "focused": .bool(workspace.focused)])
                    }),
                ])
            }),
        ])
    }
}

public struct BatterySnapshot: Snapshot {
    public enum PowerSource: String, Sendable {
        case battery, ac
    }

    public static let topic = Topic.battery
    /// Nil on a Mac without a battery.
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
    /// Milliseconds since 1970, on a whole minute.
    public var epochMilliseconds: Double

    public init(epochMilliseconds: Double) {
        self.epochMilliseconds = epochMilliseconds
    }

    public var json: JSON { .object(["epoch": .number(epochMilliseconds)]) }
}
