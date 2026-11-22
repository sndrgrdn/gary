import Foundation

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

    public init(_ capabilities: [CapabilityDeclaration]) {
        uses = Set(capabilities.filter(\.installs).map(\.name))
        topics = Set(capabilities.filter(\.publishes).map(\.name))
    }
}
