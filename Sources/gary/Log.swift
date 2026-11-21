import Foundation

let tracing = ProcessInfo.processInfo.environment["GARY_TRACE"] == "1"

func now() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_REALTIME, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

func log(_ message: String) {
    print(String(format: "%.6f ", now()) + message)
}

struct Trace {
    let cause: String
    let start: Double

    init(_ cause: String, start: Double = now()) {
        self.cause = cause
        self.start = start
    }
}
