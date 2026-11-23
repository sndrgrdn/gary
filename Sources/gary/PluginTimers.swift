import Foundation

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
