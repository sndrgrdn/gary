import Foundation

public enum CapabilityError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case duplicateName(String)

    public var description: String {
        switch self {
        case .invalidName(let name): return "capability name \"\(name)\" must be a lowercase letter followed by lowercase letters, digits or hyphens"
        case .duplicateName(let name): return "capability \(name) is registered twice"
        }
    }
}

public struct CapabilityNames: Equatable, Sendable {
    public let uses: Set<String>

    public init(uses: [String]) throws {
        var names: Set<String> = []
        for name in uses {
            guard isCapabilityName(name) else { throw CapabilityError.invalidName(name) }
            guard names.insert(name).inserted else { throw CapabilityError.duplicateName(name) }
        }
        self.uses = names
    }
}

private func isCapabilityName(_ name: String) -> Bool {
    guard let first = name.first, first.isASCII, first.isLowercase else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
}
