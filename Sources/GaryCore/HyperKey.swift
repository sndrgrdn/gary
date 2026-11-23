import Foundation

public enum HyperKey {
    public static let capsLock: Int64 = 0x39
    public static let f18: Int64 = 0x4F

    public struct Mapping: Codable, Hashable, Sendable {
        public let source: UInt64
        public let destination: UInt64

        public init(source: UInt64, destination: UInt64) {
            self.source = source
            self.destination = destination
        }

        var isCapsLock: Bool {
            source == HyperKey.capsLockToF18.source
        }
    }

    public static let capsLockToF18 = Mapping(source: 0x7_0000_0039, destination: 0x7_0000_006D)

    public static func claim(_ mappings: [Mapping]) -> (mappings: [Mapping], replaced: [Mapping])? {
        let caps = mappings.filter(\.isCapsLock)
        guard caps != [capsLockToF18] else { return nil }
        return (mappings.filter { !$0.isCapsLock } + [capsLockToF18], caps.filter { $0 != capsLockToF18 })
    }

    public static func giveBack(_ mappings: [Mapping], restoring replaced: [Mapping]) -> [Mapping]? {
        guard mappings.filter(\.isCapsLock) == [capsLockToF18] else { return nil }
        return mappings.filter { !$0.isCapsLock } + replaced
    }

    public enum Event: Equatable, Sendable {
        case keyDown(Int64, autorepeat: Bool)
        case keyUp(Int64)
        case flagsChanged(Int64)
    }

    public enum Decision: Equatable, Sendable {
        case pass
        case drop
        case flags(UInt64)
        case modifier(UInt64)
        case remap
    }

    public enum Flags {
        public static let capsLock: UInt64 = 0x10000
        public static let shift: UInt64 = 0x20000 | 0x02
        public static let hyper: UInt64 = 0x40000 | 0x80000 | 0x100000 | 0x01 | 0x20 | 0x08
        static let function: UInt64 = 0x800000
    }

    public struct Gate: Sendable {
        public var shift: Bool
        public private(set) var held = false

        public init(shift: Bool = false) {
            self.shift = shift
        }

        public mutating func decide(_ event: Event, flags: UInt64) -> Decision {
            switch event {
            case let .keyDown(code, autorepeat) where code == f18:
                guard !autorepeat else { return .drop }
                held = true
                return .modifier(hyper(flags & ~Flags.function))
            case .keyUp(f18):
                held = false
                return .modifier(flags & ~(Flags.function | Flags.capsLock))
            case .flagsChanged(capsLock) where flags & Flags.capsLock != 0:
                return .remap
            default:
                return held ? .flags(hyper(flags)) : .pass
            }
        }

        public mutating func letGo() -> Bool {
            defer { held = false }
            return held
        }

        private func hyper(_ flags: UInt64) -> UInt64 {
            flags & ~Flags.capsLock | Flags.hyper | (shift ? Flags.shift : 0)
        }
    }
}
