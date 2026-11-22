import Foundation

public enum MediaKey: String, CaseIterable, Sendable {
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case mute
    case brightnessUp = "brightness-up"
    case brightnessDown = "brightness-down"
    case play, next, previous

    public static let capability = "mediakeys"

    static let codes: [Int: MediaKey] = [
        0: .volumeUp, 1: .volumeDown, 7: .mute, 2: .brightnessUp, 3: .brightnessDown,
        16: .play, 17: .next, 19: .next, 18: .previous, 20: .previous,
    ]

    public struct Press: Equatable, Sendable {
        public let key: MediaKey
        public let down: Bool
        public let isRepeat: Bool
    }

    public struct Gate: Sendable {
        private var held: Set<MediaKey>

        public init() {
            held = []
        }

        public mutating func swallows(_ press: Press, intercepted: Bool) -> Bool {
            guard press.down else { return held.remove(press.key) != nil }
            if intercepted {
                held.insert(press.key)
            }
            return intercepted
        }
    }

    public struct UnknownKey: Error, Equatable, CustomStringConvertible {
        public let name: String
        public var description: String {
            "unknown media key \"\(name)\"; use \(MediaKey.allCases.map(\.rawValue).joined(separator: ", "))"
        }
    }

    public static func decode(systemDefinedData data1: Int) -> Press? {
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard let key = codes[(data1 >> 16) & 0xFFFF], state == 0x0A || state == 0x0B else { return nil }
        return Press(key: key, down: state == 0x0A, isRepeat: flags & 0x1 != 0)
    }

    public static func parse(_ names: [String]) throws -> Set<MediaKey> {
        try Set(names.map { name in
            guard let key = MediaKey(rawValue: name) else { throw UnknownKey(name: name) }
            return key
        })
    }
}
