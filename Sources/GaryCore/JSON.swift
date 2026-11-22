import Foundation

public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ data: Data) throws -> JSON {
        try data.withUnsafeBytes { try JSONScanner.parse($0.bindMemory(to: UInt8.self)) }
    }

    public static func parse(_ text: String) throws -> JSON {
        var text = text
        return try text.withUTF8 { try JSONScanner.parse($0) }
    }

    public func encoded() -> Data {
        Data(text.utf8)
    }

    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    public var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (String(bytes: (try? encoder.encode(self)) ?? Data("null".utf8), encoding: .utf8) ?? "null") + "\n"
    }

    public subscript(key: String) -> JSON? {
        if case let .object(fields) = self {
            return fields[key]
        }
        return nil
    }

    public var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var number: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var array: [JSON]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var object: [String: JSON]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public func merging(_ override: JSON) -> JSON {
        guard case var .object(base) = self, case let .object(top) = override else { return override }
        for (key, value) in top {
            base[key] = base[key].map { $0.merging(value) } ?? value
        }
        return .object(base)
    }
}

extension JSON: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value) where !value.isFinite: try container.encodeNil()
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
