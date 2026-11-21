import Foundation

public enum CapabilityError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case duplicateName(String)
    case noEffect(String)

    public var description: String {
        switch self {
        case let .invalidName(name): "capability name \"\(name)\" must be a lowercase letter followed by lowercase letters, digits or hyphens"
        case let .duplicateName(name): "capability \(name) is registered twice"
        case let .noEffect(name): "capability \(name) neither installs an API nor publishes a topic"
        }
    }
}

public struct CapabilityDeclaration: Sendable {
    public let name: String
    public let installs: Bool
    public let publishes: Bool

    public init(_ name: String, installs: Bool, publishes: Bool) {
        self.name = name
        self.installs = installs
        self.publishes = publishes
    }
}

public struct CapabilityNames: Equatable, Sendable {
    public let uses: Set<String>
    public let topics: Set<String>

    public init(_ capabilities: [CapabilityDeclaration]) throws {
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
