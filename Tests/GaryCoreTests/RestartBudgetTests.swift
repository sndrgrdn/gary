import Foundation
@testable import GaryCore
import Testing

struct RestartBudgetTests {
    @Test func `allows five restarts A minute and refuses the sixth`() {
        var budget = RestartBudget(limit: 5, window: 60)
        let allowed = (0..<6).map { budget.allowsRestart(afterFailureAt: 100 + Double($0)) }
        #expect(allowed == [true, true, true, true, true, false])
    }

    @Test func `failures older than the window stop counting`() {
        var budget = RestartBudget(limit: 5, window: 60)
        let allowed = [0, 1, 2, 3, 4, 60.5, 61.5, 61.6].map { budget.allowsRestart(afterFailureAt: $0) }
        #expect(allowed == [true, true, true, true, true, true, true, false])
    }

    @Test func `a steady crash every fifteen seconds runs forever`() {
        var budget = RestartBudget(limit: 5, window: 60)
        let allowed = (0..<100).map { budget.allowsRestart(afterFailureAt: Double($0) * 15) }
        #expect(!allowed.contains(false))
    }

    @Test func `reset forgets earlier failures`() {
        var budget = RestartBudget(limit: 1, window: 60)
        let first = [budget.allowsRestart(afterFailureAt: 0), budget.allowsRestart(afterFailureAt: 1)]
        budget.reset()
        let afterReset = [budget.allowsRestart(afterFailureAt: 2), budget.allowsRestart(afterFailureAt: 3)]
        #expect(first == [true, false])
        #expect(afterReset == [true, false])
    }
}

struct ProcessExitTests {
    @Test func `kills and errors are crashes but quits and duplicates are not`() {
        #expect(ProcessExit.signaled(SIGKILL).isCrash)
        #expect(ProcessExit.signaled(SIGSEGV).isCrash)
        #expect(ProcessExit.signaled(SIGABRT).isCrash)
        #expect(ProcessExit.exited(1).isCrash)
        #expect(!ProcessExit.exited(0).isCrash)
        #expect(!ProcessExit.exited(ProcessExit.alreadyRunning).isCrash)
        #expect(!ProcessExit.signaled(SIGTERM).isCrash)
        #expect(!ProcessExit.signaled(SIGINT).isCrash)
    }

    @Test func `only the restart status asks for A restart`() {
        #expect(ProcessExit.exited(ProcessExit.restart).asksForRestart)
        #expect(!ProcessExit.exited(ProcessExit.restart).isCrash)
        #expect(!ProcessExit.exited(0).asksForRestart && !ProcessExit.exited(1).asksForRestart && !ProcessExit.signaled(SIGTERM).asksForRestart)
    }
}
