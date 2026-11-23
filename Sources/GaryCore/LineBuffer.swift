public struct LineBuffer: Sendable {
    public enum InvalidUTF8: Sendable {
        case reject
        case replace
    }

    public enum Line: Equatable, Sendable {
        case text(String)
        case tooLong(String)
        case invalidUTF8
    }

    private let limit: Int
    private let invalidUTF8: InvalidUTF8
    private var pending: [UInt8] = []
    private var skipping = false

    public init(limit: Int, invalidUTF8: InvalidUTF8) {
        self.limit = limit
        self.invalidUTF8 = invalidUTF8
    }

    public mutating func append(_ bytes: some Collection<UInt8>) -> [Line] {
        var lines: [Line] = []
        var rest = bytes[...]
        while let newline = rest.firstIndex(of: 10) {
            if let line = take(rest[..<newline], ending: true) {
                lines.append(line)
            }
            rest = rest[rest.index(after: newline)...]
        }
        if let line = take(rest, ending: false) {
            lines.append(line)
        }
        return lines
    }

    public mutating func flush() -> Line? {
        skipping = false
        return pending.isEmpty ? nil : decode(drain())
    }

    private mutating func take(_ bytes: some Collection<UInt8>, ending: Bool) -> Line? {
        if skipping {
            skipping = !ending
            return nil
        }
        let room = limit - pending.count
        pending.append(contentsOf: bytes.prefix(room))
        if bytes.count > room {
            skipping = !ending
            return .tooLong(String(decoding: drain(), as: UTF8.self))
        }
        return ending ? decode(drain()) : nil
    }

    private mutating func drain() -> [UInt8] {
        defer { pending = [] }
        return pending
    }

    private func decode(_ bytes: [UInt8]) -> Line {
        switch invalidUTF8 {
        case .reject: String(validating: bytes, as: UTF8.self).map(Line.text) ?? .invalidUTF8
        case .replace: .text(String(decoding: bytes, as: UTF8.self))
        }
    }
}
