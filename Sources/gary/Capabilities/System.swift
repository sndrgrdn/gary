import Foundation
import GaryCore

extension Capability {
    static let system = Capability(
        name: "system",
        summary: """
        CPU and memory use, sampled every 2 seconds from the kernel's counters, so watching them costs next to nothing. \
        The `cpu` fractions cover all cores since the previous sample and add up to 1. \
        `memory.used` follows Activity Monitor's Memory Used: app memory, wired memory, and compressed memory, in bytes. \
        The first value arrives half a second after the first plugin subscribes.
        """,
        types: """
        declare namespace Gary {
          interface System {
            cpu: { user: number; system: number; idle: number };
            memory: { used: number; total: number; pressure: "normal" | "warning" | "critical" };
          }
        }
        """,
        example: """
        export default {
          render(state) {
            const system = state.system;
            if (!system) return { type: "text", text: "…" };
            const cpu = Math.round((1 - system.cpu.idle) * 100);
            const memory = Math.round((system.memory.used / system.memory.total) * 100);
            return { type: "text", text: `CPU ${cpu}% MEM ${memory}%`, style: system.memory.pressure === "normal" ? "default" : "bad" };
          },
        } satisfies Gary.BarWidget;
        """,
        topic: CapabilityTopic(type: "System") { SystemTopic($0) },
    )
}

private let machHost = mach_host_self()

private final class SystemTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private var ticks = CPUTicks.read()
    private var observation: Observation?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        let timer = Timer(fire: Date() + 0.5, interval: 2, repeats: true) { [weak self] _ in self?.send() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        observation = Observation { timer.invalidate() }
    }

    private func send() {
        guard let now = CPUTicks.read(), let earlier = ticks, let memory = MemoryUse.read() else { return }
        ticks = now
        let cpu = now.load(since: earlier)
        publish(.object([
            "cpu": .object(["user": .number(cpu.user), "system": .number(cpu.system), "idle": .number(cpu.idle)]),
            "memory": .object([
                "used": .number(Double(memory.used)),
                "total": .number(Double(memory.total)),
                "pressure": .string(memory.pressure.rawValue),
            ]),
        ]), Trace("system"))
    }
}

struct CPULoad: Equatable {
    let user: Double
    let system: Double
    let idle: Double
}

struct CPUTicks: Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32

    static func read() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(machHost, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: ticks.0 &+ ticks.3, system: ticks.1, idle: ticks.2)
    }

    func load(since earlier: CPUTicks) -> CPULoad {
        let user = Double(user &- earlier.user)
        let system = Double(system &- earlier.system)
        let idle = Double(idle &- earlier.idle)
        let total = user + system + idle
        guard total > 0 else { return CPULoad(user: 0, system: 0, idle: 1) }
        return CPULoad(user: user / total, system: system / total, idle: idle / total)
    }
}

struct MemoryUse: Equatable {
    enum Pressure: String {
        case normal, warning, critical
    }

    let used: UInt64
    let total: UInt64
    let pressure: Pressure

    static func read() -> MemoryUse? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(machHost, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryUse(stats, pageSize: UInt64(vm_kernel_page_size), total: ProcessInfo.processInfo.physicalMemory, pressureLevel: level)
    }

    init(_ stats: vm_statistics64, pageSize: UInt64, total: UInt64, pressureLevel: Int32) {
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        self.total = total
        pressure = switch pressureLevel {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}
