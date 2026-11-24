import Foundation

nonisolated let tracing = ProcessInfo.processInfo.environment["GARY_TRACE"] == "1"

nonisolated func now() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_REALTIME, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

nonisolated func log(_ message: String) {
    print(String(format: "%.6f ", now()) + message)
}

nonisolated struct Trace {
    let cause: String
    let start: Double
    let id: UInt64
    var timings = Timings()

    init(_ cause: String, start: Double = now()) {
        self.cause = cause
        self.start = start
        id = TraceLog.cause(cause)
    }
}
