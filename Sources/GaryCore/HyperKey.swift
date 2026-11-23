import Foundation

public enum HyperKey {
    public static let capsLock: Int64 = 0x39
    public static let f18: Int64 = 0x4F
    public static let tappingTerm: UInt64 = 200_000_000
    public static let optionsType = "{ key?: string; shift?: boolean; tap?: string }"

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

    public enum TriggerKind: Hashable, Sendable {
        case capsLock
        case side(own: UInt64, other: UInt64, modifier: UInt64)
        case key
    }

    public struct Trigger: Hashable, Sendable {
        public let name: String
        let code: Int64
        public let kind: TriggerKind

        public static let capsLock = Trigger(name: "capsLock", code: f18, kind: .capsLock)

        public static let sides = [
            Trigger(name: "leftCommand", code: 0x37, kind: .side(own: 0x08, other: 0x10, modifier: 0x100000)),
            Trigger(name: "rightCommand", code: 0x36, kind: .side(own: 0x10, other: 0x08, modifier: 0x100000)),
            Trigger(name: "leftOption", code: 0x3A, kind: .side(own: 0x20, other: 0x40, modifier: 0x80000)),
            Trigger(name: "rightOption", code: 0x3D, kind: .side(own: 0x40, other: 0x20, modifier: 0x80000)),
            Trigger(name: "leftControl", code: 0x3B, kind: .side(own: 0x01, other: 0x2000, modifier: 0x40000)),
            Trigger(name: "rightControl", code: 0x3E, kind: .side(own: 0x2000, other: 0x01, modifier: 0x40000)),
            Trigger(name: "leftShift", code: 0x38, kind: .side(own: 0x02, other: 0x04, modifier: 0x20000)),
            Trigger(name: "rightShift", code: 0x3C, kind: .side(own: 0x04, other: 0x02, modifier: 0x20000)),
            Trigger(name: "fn", code: 0x3F, kind: .side(own: Flags.function, other: 0, modifier: Flags.function)),
        ]

        init(name: String, code: Int64, kind: TriggerKind) {
            self.name = name
            self.code = code
            self.kind = kind
        }

        public init?(named name: String) {
            if let trigger = ([Self.capsLock] + Self.sides).first(where: { $0.name == name }) {
                self = trigger
            } else if let code = KeyCombo.keyCodes[name.lowercased()] {
                self.init(name: name, code: Int64(code), kind: .key)
            } else {
                return nil
            }
        }

        public func stripping(_ flags: UInt64) -> UInt64 {
            switch kind {
            case .capsLock: flags & ~Flags.capsLock
            case let .side(own, other, modifier): flags & ~own & (flags & other == 0 ? ~modifier : ~0)
            case .key: flags
            }
        }

        func isDown(_ flags: UInt64) -> Bool {
            guard case let .side(own, _, _) = kind else { return false }
            return flags & own != 0
        }
    }

    public enum Tap: Hashable, Sendable {
        case capsLock
        case key(Int64)

        public init?(named name: String) {
            if name == Trigger.capsLock.name {
                self = .capsLock
            } else if let code = KeyCombo.keyCodes[name.lowercased()] {
                self = .key(Int64(code))
            } else {
                return nil
            }
        }
    }

    public struct Options: Hashable, Sendable {
        public var trigger: Trigger
        public var shift: Bool
        public var tap: Tap?

        public init(trigger: Trigger = .capsLock, shift: Bool = false, tap: Tap? = nil) {
            self.trigger = trigger
            self.shift = shift
            self.tap = tap
        }
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
        case tap(UInt64, Tap)
        case remap
    }

    public enum Flags {
        public static let capsLock: UInt64 = 0x10000
        public static let shift: UInt64 = 0x20000 | 0x02
        public static let hyper: UInt64 = 0x40000 | 0x80000 | 0x100000 | 0x01 | 0x20 | 0x08
        static let function: UInt64 = 0x800000
    }

    private enum Press: Equatable {
        case released
        case tapping(since: UInt64)
        case held
    }

    public struct Gate: Sendable {
        public var options: Options
        private var press = Press.released
        private var togglingCapsLock = false

        public init(_ options: Options = Options()) {
            self.options = options
        }

        public mutating func decide(_ event: Event, flags: UInt64, at time: UInt64) -> Decision {
            switch event {
            case let .keyDown(code, autorepeat) where code == options.trigger.code:
                return autorepeat ? .drop : pressed(flags & ~Flags.function, at: time)
            case let .keyUp(code) where code == options.trigger.code:
                return released(flags & ~Flags.function, at: time)
            case let .flagsChanged(code) where code == options.trigger.code:
                return options.trigger.isDown(flags) ? pressed(flags, at: time) : released(flags, at: time)
            case .flagsChanged(capsLock) where togglingCapsLock:
                togglingCapsLock = false
                return .pass
            case .flagsChanged(capsLock) where options.trigger.kind == .capsLock && flags & Flags.capsLock != 0:
                return .remap
            case .keyDown where press != .released:
                press = .held
                return .flags(hyper(flags))
            default:
                return press == .released ? .pass : .flags(hyper(flags))
            }
        }

        public mutating func letGo() -> Bool {
            defer { press = .released }
            return press != .released
        }

        private mutating func pressed(_ flags: UInt64, at time: UInt64) -> Decision {
            press = options.tap == nil ? .held : .tapping(since: time)
            return .modifier(hyper(flags))
        }

        private mutating func released(_ flags: UInt64, at time: UInt64) -> Decision {
            defer { press = .released }
            let flags = options.trigger.stripping(flags)
            guard case let .tapping(since) = press, time < since + tappingTerm, let tap = options.tap else { return .modifier(flags) }
            togglingCapsLock = tap == .capsLock
            return .tap(flags, tap)
        }

        private func hyper(_ flags: UInt64) -> UInt64 {
            options.trigger.stripping(flags) | Flags.hyper | (options.shift ? Flags.shift : 0)
        }
    }
}
