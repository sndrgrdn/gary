import Foundation
@preconcurrency import JavaScriptCore

typealias StartTimer = @Sendable (_ seconds: TimeInterval, _ repeats: Bool, _ queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void)
    -> @Sendable () -> Void

nonisolated func dispatchTimer(
    _ seconds: TimeInterval,
    _ repeats: Bool,
    _ queue: DispatchQueue,
    _ fire: @escaping @Sendable () -> Void,
) -> @Sendable () -> Void {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
        deadline: .now() + seconds,
        repeating: repeats ? seconds : .infinity,
        leeway: .milliseconds(max(1, min(100, Int(seconds * 100)))),
    )
    timer.setEventHandler(handler: fire)
    timer.resume()
    return { timer.cancel() }
}

extension PluginRuntime {
    func installTimers(in context: JSContext) throws {
        let add: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] callback, milliseconds, repeats in
            self?.assumeIsolated { $0.addTimer(callback, milliseconds: milliseconds, repeats: repeats) } ?? 0
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in
            self?.assumeIsolated { $0.timers.removeValue(forKey: id)?() }
        }
        try check(in: context) { context.evaluateScript(PluginScripts.timers)?.call(withArguments: [add, clear]) }
    }

    func addTimer(_ callback: JSValue, milliseconds: Double, repeats: Bool) -> Int {
        let id = nextTimer
        nextTimer += 1
        let interval = max(repeats ? 10 : 0, milliseconds.isFinite ? milliseconds : 0) / 1000
        timers[id] = metrics.timer(repeats: repeats, startTimer(interval, repeats, queue) { [weak self] in
            self?.assumeIsolated { runtime in
                guard runtime.isRunning else { return }
                if !repeats {
                    runtime.timers.removeValue(forKey: id)?()
                }
                runtime.callBack(callback, [], Trace("timer"), cause: .timer)
            }
        })
        return id
    }
}
