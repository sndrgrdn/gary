import Foundation

public struct DockReservation: Equatable, Sendable {
    public enum Edge: String, CaseIterable, Sendable {
        case bottom, left, right
    }

    public let edge: Edge
    public let size: Double

    public var orientation: Int32 {
        switch edge {
        case .bottom: return 2
        case .left: return 3
        case .right: return 4
        }
    }

    public func rect(in screen: CGSize) -> CGRect? {
        switch edge {
        case .bottom:
            guard size <= screen.height / 2 else { return nil }
            return CGRect(x: 0, y: screen.height - size, width: screen.width, height: size)
        case .left:
            guard size <= screen.width / 2 else { return nil }
            return CGRect(x: 0, y: 0, width: size, height: screen.height)
        case .right:
            guard size <= screen.width / 2 else { return nil }
            return CGRect(x: screen.width - size, y: 0, width: size, height: screen.height)
        }
    }

    public var json: JSON { .object(["edge": .string(edge.rawValue), "size": .number(size)]) }
}

public enum DockRequest: Equatable, Sendable {
    case reserve(DockReservation)
    case release, hide, show, restore, state

    public static let methods = ["reserve", "release", "hide", "show", "restore", "state"]

    public static func parse(_ call: HostCall) throws -> DockRequest {
        switch call.method {
        case "reserve":
            let raw = try call.string(0, "edge")
            guard let edge = DockReservation.Edge(rawValue: raw) else {
                throw call.fail("edge must be one of \(DockReservation.Edge.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let size = try call.number(1, "size")
            guard size > 0 else { throw call.fail("size must be more than 0") }
            return .reserve(DockReservation(edge: edge, size: size))
        case "release": return .release
        case "hide": return .hide
        case "show": return .show
        case "restore": return .restore
        case "state": return .state
        default: throw call.unknownMethod
        }
    }
}

public struct Claims<Owner: Hashable, Value: Equatable> {
    private var entries: [(owner: Owner, value: Value)] = []

    public init() {}

    public var current: Value? { entries.last?.value }

    public mutating func claim(_ value: Value, by owner: Owner) {
        entries.removeAll { $0.owner == owner }
        entries.append((owner, value))
    }

    public mutating func release(_ owner: Owner) {
        entries.removeAll { $0.owner == owner }
    }
}
