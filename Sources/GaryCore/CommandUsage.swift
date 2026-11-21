public struct CommandUsage: Sendable {
    public let syntax: String
    public let description: String
    public let example: String?

    public init(_ syntax: String, _ description: String, _ example: String?) {
        self.syntax = syntax
        self.description = description
        self.example = example
    }
}
