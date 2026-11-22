import Foundation

struct JSONScanner {
    private enum Open {
        case array([JSON])
        case object([String: JSON], key: String)
    }

    private static let maxDepth = 512

    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> JSON {
        var scanner = JSONScanner(bytes: bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            scanner.index = 3
        }
        let value = try scanner.document()
        scanner.skipSpace()
        guard scanner.index == bytes.count else { throw scanner.fail("unexpected character after the value") }
        return value
    }

    private func fail(_ reason: String) -> JSON.ParseError {
        JSON.ParseError(description: "invalid JSON: \(reason) at byte \(index)")
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipSpace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            index += 1
        }
    }

    private mutating func expect(_ byte: UInt8) throws {
        skipSpace()
        guard current == byte else { throw fail("expected \(Character(UnicodeScalar(byte)))") }
        index += 1
    }

    private mutating func skip(_ byte: UInt8) -> Bool {
        skipSpace()
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func document() throws -> JSON {
        var open: [Open] = []
        while true {
            guard var value = try start(&open) else { continue }
            while !open.isEmpty {
                guard let closed = try add(value, to: &open[open.count - 1]) else { break }
                open.removeLast()
                value = closed
            }
            if open.isEmpty {
                return value
            }
        }
    }

    private mutating func start(_ open: inout [Open]) throws -> JSON? {
        skipSpace()
        switch current {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            guard open.count < Self.maxDepth else { throw fail("nested deeper than \(Self.maxDepth)") }
            let array = current == UInt8(ascii: "[")
            index += 1
            if skip(array ? UInt8(ascii: "]") : UInt8(ascii: "}")) {
                return array ? .array([]) : .object([:])
            }
            try open.append(array ? .array([]) : .object([:], key: key()))
            return nil
        case UInt8(ascii: "\""): return try .string(string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case nil: throw fail("unexpected end of input")
        default: return try .number(number())
        }
    }

    private mutating func key() throws -> String {
        skipSpace()
        guard current == UInt8(ascii: "\"") else { throw fail("expected a key") }
        let key = try string()
        try expect(UInt8(ascii: ":"))
        return key
    }

    private mutating func add(_ value: JSON, to parent: inout Open) throws -> JSON? {
        switch parent {
        case var .array(items):
            parent = .array([])
            items.append(value)
            guard try more(closing: UInt8(ascii: "]")) else { return .array(items) }
            parent = .array(items)
        case .object(var fields, let key):
            parent = .array([])
            if fields[key] == nil {
                fields[key] = value
            }
            guard try more(closing: UInt8(ascii: "}")) else { return .object(fields) }
            parent = try .object(fields, key: self.key())
        }
        return nil
    }

    private mutating func more(closing: UInt8) throws -> Bool {
        if skip(UInt8(ascii: ",")) {
            return !skip(closing)
        }
        try expect(closing)
        return false
    }

    private mutating func literal(_ word: String, _ value: JSON) throws -> JSON {
        let end = index + word.utf8.count
        guard end <= bytes.count, bytes[index..<end].elementsEqual(word.utf8) else { throw fail("unknown literal") }
        index = end
        return value
    }

    private mutating func digits() -> Int {
        let start = index
        while let byte = current, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            index += 1
        }
        return index - start
    }

    private mutating func number() throws -> Double {
        let start = index
        let negative = current == UInt8(ascii: "-")
        if negative {
            index += 1
        }
        let integerStart = index
        let integerDigits = digits()
        guard integerDigits > 0 else { throw fail("unexpected character") }
        guard integerDigits == 1 || bytes[integerStart] != UInt8(ascii: "0") else { throw fail("leading zero in a number") }
        let mantissaEnd = try fraction()
        let scaled = try exponent()
        guard mantissaEnd == integerStart + integerDigits, !scaled, integerDigits <= 15 else {
            return try double(from: start, mantissa: integerStart..<mantissaEnd)
        }
        var value = 0
        for byte in bytes[integerStart..<index] {
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return negative ? -Double(value) : Double(value)
    }

    private mutating func fraction() throws -> Int {
        guard current == UInt8(ascii: ".") else { return index }
        index += 1
        guard digits() > 0 else { throw fail("expected a digit after the decimal point") }
        return index
    }

    private mutating func exponent() throws -> Bool {
        guard current == UInt8(ascii: "e") || current == UInt8(ascii: "E") else { return false }
        index += 1
        if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") {
            index += 1
        }
        guard digits() > 0 else { throw fail("expected a digit in the exponent") }
        return true
    }

    private func double(from start: Int, mantissa: Range<Int>) throws -> Double {
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        guard let value = Double(text), value.isFinite,
              value != 0 || !bytes[mantissa].contains(where: { $0 > UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
        else {
            throw fail("number out of range")
        }
        return value
    }

    private mutating func string() throws -> String {
        index += 1
        let start = index
        while let byte = current, byte != UInt8(ascii: "\""), byte != UInt8(ascii: "\\"), byte >= 0x20 {
            index += 1
        }
        if current == UInt8(ascii: "\"") {
            defer { index += 1 }
            return try text(UnsafeBufferPointer(rebasing: bytes[start..<index]))
        }
        var unescaped = Array(bytes[start..<index])
        while true {
            guard let byte = current else { throw fail("unterminated string") }
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return try unescaped.withUnsafeBufferPointer { try text($0) }
            case UInt8(ascii: "\\"):
                try unescape(into: &unescaped)
            case ..<0x20:
                index -= 1
                throw fail("control character in a string")
            default:
                unescaped.append(byte)
            }
        }
    }

    private func text(_ utf8: UnsafeBufferPointer<UInt8>) throws -> String {
        guard let text = String(validating: utf8, as: UTF8.self) else { throw fail("invalid UTF-8 in a string") }
        return text
    }

    private mutating func unescape(into unescaped: inout [UInt8]) throws {
        guard let byte = current else { throw fail("unterminated string") }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): unescaped.append(byte)
        case UInt8(ascii: "b"): unescaped.append(0x08)
        case UInt8(ascii: "f"): unescaped.append(0x0C)
        case UInt8(ascii: "n"): unescaped.append(0x0A)
        case UInt8(ascii: "r"): unescaped.append(0x0D)
        case UInt8(ascii: "t"): unescaped.append(0x09)
        case UInt8(ascii: "u"):
            var scalar = try hex()
            if (0xD800..<0xDC00).contains(scalar) {
                guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                    throw fail("unpaired surrogate")
                }
                index += 2
                let low = try hex()
                guard (0xDC00..<0xE000).contains(low) else { throw fail("unpaired surrogate") }
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(scalar) else { throw fail("unpaired surrogate") }
            UTF8.encode(scalar) { unescaped.append($0) }
        default:
            throw fail("unknown escape")
        }
    }

    private mutating func hex() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("short unicode escape") }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            let digit: UInt8 = switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: throw fail("bad unicode escape")
            }
            value = value << 4 | UInt32(digit)
        }
        index += 4
        return value
    }
}

extension JSON {
    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .number(value) where !value.isFinite: out += "null"
        case let .number(value): out += Self.text(of: value)
        case let .string(value): Self.write(value, to: &out)
        case let .array(items):
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 {
                    out += ","
                }
                item.write(to: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            for (offset, key) in fields.keys.sorted().enumerated() {
                if offset > 0 {
                    out += ","
                }
                Self.write(key, to: &out)
                out += ":"
                fields[key]?.write(to: &out)
            }
            out += "}"
        }
    }

    private static func text(of number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 {
            return number == 0 && number.sign == .minus ? "-0" : String(Int64(number))
        }
        let text = number.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func write(_ string: String, to out: inout String) {
        out += "\""
        var start = string.utf8.startIndex
        for index in string.utf8.indices {
            let byte = string.utf8[index]
            let escaped: String? = switch byte {
            case UInt8(ascii: "\""): #"\""#
            case UInt8(ascii: "\\"): #"\\"#
            case 0x0A: #"\n"#
            case 0x0D: #"\r"#
            case 0x09: #"\t"#
            case 0x08: #"\b"#
            case 0x0C: #"\f"#
            case ..<0x20: String(format: #"\u%04x"#, byte)
            default: nil
            }
            if let escaped {
                out += string[start..<index]
                out += escaped
                start = string.utf8.index(after: index)
            }
        }
        out += string[start...]
        out += "\""
    }
}
