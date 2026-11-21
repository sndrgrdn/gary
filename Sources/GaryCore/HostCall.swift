import Foundation

public struct ArgumentError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct HostCall: Equatable, Sendable {
    public let api: String?
    public let method: String
    public let arguments: [JSON]

    public init(api: String?, method: String, arguments: [JSON]) {
        self.api = api
        self.method = method
        self.arguments = arguments
    }

    public var name: String { "host." + (api.map { "\($0)." } ?? "") + method }

    public func fail(_ reason: String) -> ArgumentError { ArgumentError("\(name): \(reason)") }

    public var unknownMethod: ArgumentError { ArgumentError("\(name) is not a method") }

    public func string(_ index: Int, _ label: String) throws -> String {
        guard let value = argument(index)?.string else { throw fail("\(label) must be a string") }
        return value
    }

    public func optionalString(_ index: Int, _ label: String) throws -> String? {
        guard let value = argument(index), value != .null else { return nil }
        guard let string = value.string else { throw fail("\(label) must be a string") }
        return string
    }

    public func number(_ index: Int, _ label: String) throws -> Double {
        guard let value = argument(index)?.number, value.isFinite else { throw fail("\(label) must be a number") }
        return value
    }

    public func fraction(_ index: Int, _ label: String) throws -> Double {
        let value = try number(index, label)
        guard (0...1).contains(value) else { throw fail("\(label) must be a number from 0 to 1") }
        return value
    }

    public func bool(_ index: Int, _ label: String) throws -> Bool {
        guard let value = argument(index)?.bool else { throw fail("\(label) must be true or false") }
        return value
    }

    public func strings(_ index: Int, _ label: String) throws -> [String] {
        guard let items = argument(index)?.array, case let strings = items.compactMap(\.string), strings.count == items.count else {
            throw fail("\(label) must be an array of strings")
        }
        return strings
    }

    public func choice<Choice: RawRepresentable & CaseIterable>(_ index: Int, _ label: String, default fallback: Choice) throws -> Choice
    where Choice.RawValue == String {
        guard let raw = try optionalString(index, label) else { return fallback }
        guard let value = Choice(rawValue: raw) else {
            throw fail("\(label) must be " + Choice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or "))
        }
        return value
    }

    public func path(_ index: Int, home: String) throws -> String {
        let raw = try string(index, "path")
        guard let path = absolutePath(raw, home: home) else { throw fail("path \"\(raw)\" must be absolute or start with ~/") }
        return path
    }

    private func argument(_ index: Int) -> JSON? {
        index < arguments.count ? arguments[index] : nil
    }
}

public func absolutePath(_ raw: String, home: String) -> String? {
    let expanded: String
    if raw == "~" {
        expanded = home
    } else if raw.hasPrefix("~/") {
        expanded = home + raw.dropFirst()
    } else if raw.hasPrefix("/") {
        expanded = raw
    } else {
        return nil
    }
    var parts: [Substring] = []
    for part in expanded.split(separator: "/") where part != "." {
        if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
}
