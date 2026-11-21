import Foundation

public enum CapabilityError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case duplicateName(String)
    case noEffect(String)

    public var description: String {
        switch self {
        case .invalidName(let name): return "capability name \"\(name)\" must be a lowercase letter followed by lowercase letters, digits or hyphens"
        case .duplicateName(let name): return "capability \(name) is registered twice"
        case .noEffect(let name): return "capability \(name) neither installs an API nor publishes a topic"
        }
    }
}

public struct CapabilityNames: Equatable, Sendable {
    public let uses: Set<String>
    public let topics: Set<String>

    public init(_ capabilities: [(name: String, installs: Bool, publishes: Bool)]) throws {
        var names: Set<String> = []
        for capability in capabilities {
            guard isCapabilityName(capability.name) else { throw CapabilityError.invalidName(capability.name) }
            guard names.insert(capability.name).inserted else { throw CapabilityError.duplicateName(capability.name) }
            guard capability.installs || capability.publishes else { throw CapabilityError.noEffect(capability.name) }
        }
        uses = Set(capabilities.filter(\.installs).map(\.name))
        topics = Set(capabilities.filter(\.publishes).map(\.name))
    }
}

private func isCapabilityName(_ name: String) -> Bool {
    guard let first = name.first, first.isASCII, first.isLowercase else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
}
