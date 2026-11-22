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

    public var summary: String {
        "\(failures.count) failures in \(Int(window)) s"
    }

    public mutating func step(after exit: ProcessExit, at time: TimeInterval) -> SupervisorStep {
        guard exit.isCrash || exit.asksForRestart else { return .stop }
        guard allowsRestart(afterFailureAt: time) else { return .giveUp }
        return exit.asksForRestart ? .restartNow : .restartAfterPause
    }
}

public enum SupervisorStep: Equatable, Sendable {
    case restartNow, restartAfterPause, stop, giveUp
}

public enum ProcessExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public static let alreadyRunning: Int32 = 75
    public static let restart: Int32 = 76

    public var asksForRestart: Bool {
        self == .exited(Self.restart)
    }

    public var isCrash: Bool {
        switch self {
        case let .exited(status): status != 0 && status != Self.alreadyRunning && status != Self.restart
        case let .signaled(signal): ![SIGTERM, SIGINT, SIGHUP].contains(signal)
        }
    }

    public var description: String {
        switch self {
        case let .exited(status): "exited with status \(status)"
        case let .signaled(signal): "killed by signal \(signal) (\(String(cString: strsignal(signal))))"
        }
    }
}
