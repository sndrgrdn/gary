import Foundation

public enum MenuBarRequest: String, CaseIterable, Sendable {
    case hide, restore, state

    public static let methods = allCases.map(\.rawValue)

    public static func parse(_ call: HostCall) throws -> MenuBarRequest {
        guard let request = MenuBarRequest(rawValue: call.method) else { throw call.unknownMethod }
        return request
    }
}
