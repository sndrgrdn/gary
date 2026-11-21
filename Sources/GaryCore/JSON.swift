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

    public static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(self)
    }

    public var text: String { String(decoding: encoded(), as: UTF8.self) }

    public var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: try! encoder.encode(self), as: UTF8.self) + "\n"
    }

    public subscript(key: String) -> JSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }

    public func merging(_ override: JSON) -> JSON {
        guard case .object(var base) = self, case .object(let top) = override else { return override }
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
            self = .object(try container.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value) where !value.isFinite: try container.encodeNil()
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
