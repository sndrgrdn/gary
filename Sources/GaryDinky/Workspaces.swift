import Foundation
import GaryCore

public struct SpaceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "\(rawValue)" }
}

/// One display's Spaces as WindowServer reports them now.
public struct DisplaySpaces: Equatable, Sendable {
    public var uuid: String
    public var current: SpaceID
    public var spaces: [SpaceID]

    public init(uuid: String, current: SpaceID, spaces: [SpaceID]) {
        self.uuid = uuid
        self.current = current
        self.spaces = spaces
    }
}

public struct DinkyParseError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// dinky's workspace names by the Space each one lives on.
public struct WorkspaceMap: Equatable, Sendable {
    public private(set) var names: [SpaceID: String]

    public init(_ names: [SpaceID: String] = [:]) { self.names = names }

    public subscript(space: SpaceID) -> String? { names[space] }

    /// `debug-state` is a debugging aid, not a stable API, so this reads only its `workspaces` object, a map
    /// from workspace name to Space ID, and throws when that shape changes.
    public static func parseDebugState(_ text: String) throws -> WorkspaceMap {
        guard let json = try? JSON.parse(text), json.object != nil else { throw DinkyParseError(description: "debug-state is not a JSON object") }
        guard let workspaces = json["workspaces"]?.object else { throw DinkyParseError(description: "debug-state has no workspaces object") }
        var names: [SpaceID: String] = [:]
        for (name, value) in workspaces {
            guard let number = value.number, number > 0, number.rounded() == number, number < 1.8e19 else {
                throw DinkyParseError(description: "debug-state workspace \(name) has no Space ID")
            }
            names[SpaceID(UInt64(number))] = name
        }
        return WorkspaceMap(names)
    }

    /// A name lives on one Space and a Space holds one name, so learning a pair drops older pairs with either.
    public mutating func learn(_ name: String, on space: SpaceID) {
        names = names.filter { $0.value != name }
        names[space] = name
    }
}

public struct WorkspaceRow: Equatable, Sendable {
    public var name: String
    public var focused: Bool
    public var monitor: Int
}

/// The format `list-workspaces --all` gets in learned mode, and the parser for its output.
public let workspaceRowsCommand = "list-workspaces --all --format '%{workspace}\t%{workspace-is-focused}\t%{monitor-id}'"
public let focusedWorkspaceCommand = "list-workspaces --focused --format '%{workspace}'"

public func parseWorkspaceRows(_ text: String) throws -> [WorkspaceRow] {
    try text.split(separator: "\n").map { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, !fields[0].isEmpty, let monitor = Int(fields[2]), ["true", "false"].contains(fields[1]) else {
            throw DinkyParseError(description: "unexpected list-workspaces line \"\(line.prefix(80))\"")
        }
        return WorkspaceRow(name: fields[0], focused: fields[1] == "true", monitor: monitor)
    }
}

public func parseFocusedWorkspace(_ text: String) -> String? {
    text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
}

/// Where workspace names come from.
public enum WorkspaceNames: Equatable, Sendable {
    /// No dinky: each display's user Spaces, numbered from 1 in Mission Control order.
    case native
    /// dinky's own map, read from `debug-state`.
    case mapped(WorkspaceMap)
    /// `debug-state` unreadable: names from `list-workspaces`, each paired with a Space once the bar sees it focused.
    case learned(rows: [WorkspaceRow], map: WorkspaceMap)

    /// Whether a Space has a name here. A Space the map lacks means the map is stale.
    public func knows(_ space: SpaceID) -> Bool {
        switch self {
        case .native: return true
        case .mapped(let map), .learned(_, let map): return map[space] != nil
        }
    }

    public func snapshot(live: [DisplaySpaces], active: SpaceID) -> WorkspacesSnapshot {
        switch self {
        case .native:
            return WorkspacesSnapshot(source: .native, displays: live.map { display in
                DisplayWorkspaces(display: display.uuid, workspaces: display.spaces.enumerated().map { index, space in
                    Workspace(name: "\(index + 1)", visible: space == display.current, focused: space == active)
                })
            })
        case .mapped(let map):
            return WorkspacesSnapshot(source: .dinky, displays: live.map { display in
                let named = display.spaces.compactMap { space in map[space].map { (name: $0, space: space) } }
                return DisplayWorkspaces(display: display.uuid, workspaces: named.sorted { byName($0.name, $1.name) }.map { entry in
                    Workspace(name: entry.name, visible: entry.space == display.current, focused: entry.space == active)
                })
            })
        case .learned(let rows, let map):
            return WorkspacesSnapshot(source: .dinky, displays: live.enumerated().map { index, display in
                let names = rows.filter { $0.monitor == index + 1 }.map(\.name).sorted(by: byName)
                return DisplayWorkspaces(display: display.uuid, workspaces: names.map { name in
                    Workspace(name: name, visible: map[display.current] == name, focused: map[active] == name)
                })
            })
        }
    }
}

private func byName(_ a: String, _ b: String) -> Bool {
    switch (Int(a), Int(b)) {
    case let (x?, y?): return x < y
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): return a < b
    }
}
