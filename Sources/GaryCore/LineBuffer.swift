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
    private let breaksOnCarriageReturn: Bool
    private var pending: [UInt8] = []
    private var skipping = false
    private var afterCarriageReturn = false

    public init(limit: Int, invalidUTF8: InvalidUTF8, breaksOnCarriageReturn: Bool = false) {
        self.limit = limit
        self.invalidUTF8 = invalidUTF8
        self.breaksOnCarriageReturn = breaksOnCarriageReturn
    }

    public mutating func append(_ bytes: some Collection<UInt8>) -> [Line] {
        var lines: [Line] = []
        var rest = bytes[...]
        while true {
            if afterCarriageReturn, let first = rest.first {
                afterCarriageReturn = false
                if first == 10 {
                    rest = rest.dropFirst()
                    continue
                }
            }
            guard let end = rest.firstIndex(where: { $0 == 10 || (breaksOnCarriageReturn && $0 == 13) }) else { break }
            if let line = take(rest[..<end], ending: true) {
                lines.append(line)
            }
            afterCarriageReturn = rest[end] == 13
            rest = rest[rest.index(after: end)...]
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
