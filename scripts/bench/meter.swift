import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let tick = Double(timebase.numer) / Double(timebase.denom)

struct Sample {
    var footprint: UInt64
    var cpu: Double
    var wakeups: UInt64
    var time: Double
}

func sample(_ pid: Int32) -> Sample? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard result == 0 else { return nil }
    return Sample(
        footprint: info.ri_phys_footprint, cpu: Double(info.ri_user_time + info.ri_system_time) * tick / 1e9,
        wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups, time: Date().timeIntervalSince1970
    )
}

let seconds = Double(CommandLine.arguments[1])!
let targets = CommandLine.arguments.dropFirst(2).map { argument -> (String, Int32) in
    let parts = argument.split(separator: "=")
    return (String(parts[0]), Int32(parts[1])!)
}
let start = targets.map { sample($0.1) }
Thread.sleep(forTimeInterval: seconds)
let end = targets.map { sample($0.1) }
for (index, (name, pid)) in targets.enumerated() {
    guard let a = start[index], let b = end[index] else {
        print("\(name) pid=\(pid) gone")
        continue
    }
    let window = b.time - a.time
    print(String(format: "%@ pid=%d footprint_start_mb=%.2f footprint_end_mb=%.2f cpu_pct=%.4f cpu_s=%.4f wakeups_per_s=%.2f window_s=%.1f",
                 name, pid, Double(a.footprint) / 1_048_576, Double(b.footprint) / 1_048_576,
                 (b.cpu - a.cpu) / window * 100, b.cpu - a.cpu, Double(b.wakeups - a.wakeups) / window, window))
}
