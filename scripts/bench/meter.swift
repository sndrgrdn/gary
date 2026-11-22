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
    var instructions: UInt64
    var cycles: UInt64
    var performanceCycles: UInt64
    var energy: UInt64
    var time: Double
}

func sample(_ pid: Int32) -> Sample? {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard result == 0 else { return nil }
    return Sample(
        footprint: info.ri_phys_footprint, cpu: Double(info.ri_user_time + info.ri_system_time) * tick / 1e9,
        wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups, instructions: info.ri_instructions, cycles: info.ri_cycles,
        performanceCycles: info.ri_pcycles, energy: info.ri_energy_nj, time: Date().timeIntervalSince1970,
    )
}

struct Target {
    let name: String
    let pid: Int32
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("meter: \(message)\n".utf8))
    exit(64)
}

guard CommandLine.arguments.count > 1, let seconds = Double(CommandLine.arguments[1]) else { fail("usage: meter <seconds> <name=pid>...") }
let targets = CommandLine.arguments.dropFirst(2).map { argument -> Target in
    let parts = argument.split(separator: "=")
    guard parts.count == 2, let pid = Int32(parts[1]) else { fail("expected name=pid, got \(argument)") }
    return Target(name: String(parts[0]), pid: pid)
}

let start = targets.map { sample($0.pid) }
Thread.sleep(forTimeInterval: seconds)
let end = targets.map { sample($0.pid) }
for (index, target) in targets.enumerated() {
    guard let first = start[index], let last = end[index] else {
        print("\(target.name) pid=\(target.pid) gone")
        continue
    }
    let window = last.time - first.time
    print(String(
        format: "%@ pid=%d footprint_start_mb=%.2f footprint_end_mb=%.2f cpu_pct=%.4f cpu_s=%.4f wakeups_per_s=%.2f "
            + "minstructions_per_s=%.2f mcycles_per_s=%.2f pcycles_pct=%.1f energy_mw=%.2f window_s=%.1f",
        target.name,
        target.pid,
        Double(first.footprint) / 1_048_576,
        Double(last.footprint) / 1_048_576,
        (last.cpu - first.cpu) / window * 100,
        last.cpu - first.cpu,
        Double(last.wakeups - first.wakeups) / window,
        Double(last.instructions - first.instructions) / window / 1e6,
        Double(last.cycles - first.cycles) / window / 1e6,
        Double(last.performanceCycles - first.performanceCycles) / Double(max(1, last.cycles - first.cycles)) * 100,
        Double(last.energy - first.energy) / window / 1e6,
        window,
    ))
}
