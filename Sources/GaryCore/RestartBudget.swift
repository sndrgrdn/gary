import Foundation

public struct RestartBudget: Equatable, Sendable {
    public let limit: Int
    public let window: TimeInterval
    public private(set) var failures: [TimeInterval] = []

    public init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    public mutating func allowsRestart(afterFailureAt time: TimeInterval) -> Bool {
        failures = failures.filter { time - $0 < window } + [time]
        return failures.count <= limit
    }

    public mutating func reset() {
        failures = []
    }

    public var summary: String { "\(failures.count) failures in \(Int(window)) s" }
}

public enum ProcessExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public static let alreadyRunning: Int32 = 75

    public var isCrash: Bool {
        switch self {
        case .exited(let status): return status != 0 && status != Self.alreadyRunning
        case .signaled(let signal): return ![SIGTERM, SIGINT, SIGHUP].contains(signal)
        }
    }

    public var description: String {
        switch self {
        case .exited(let status): return "exited with status \(status)"
        case .signaled(let signal): return "killed by signal \(signal) (\(String(cString: strsignal(signal))))"
        }
    }
}
