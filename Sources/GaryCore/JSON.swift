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
        do {
            return try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            throw ParseError(description: "invalid JSON: \(error.localizedDescription)")
        }
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(self)
    }

    public var text: String {
        String(decoding: encoded(), as: UTF8.self)
    }

    public var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: try! encoder.encode(self), as: UTF8.self) + "\n"
    }

    public subscript(key: String) -> JSON? {
        if case let .object(fields) = self {
            return fields[key]
        }
        return nil
    }

    public var string: String? {
        if case let .string(s) = self {
            return s
        }; return nil
    }

    public var number: Double? {
        if case let .number(n) = self {
            return n
        }; return nil
    }

    public var bool: Bool? {
        if case let .bool(b) = self {
            return b
        }; return nil
    }

    public var array: [JSON]? {
        if case let .array(a) = self {
            return a
        }; return nil
    }

    public var object: [String: JSON]? {
        if case let .object(o) = self {
            return o
        }; return nil
    }

    public func merging(_ override: JSON) -> JSON {
        guard case var .object(base) = self, case let .object(top) = override else { return override }
        for (key, value) in top {
            base[key] = base[key].map { $0.merging(value) } ?? value
        }
        return .object(base)
    }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSON].self))
        }
    }

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
