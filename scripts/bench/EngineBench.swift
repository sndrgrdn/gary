import Foundation
@testable import gary
import GaryCore
import Testing

private let environment = ProcessInfo.processInfo.environment
private let benchEngine = PluginEngine()
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let gallery = URL(fileURLWithPath: environment["GARY_PLUGINS"] ?? NSHomeDirectory() + "/Developer/gary-plugins")
private let stopMessage = "stopped after running longer than"
private let runawayID = "bench.runaway"

private func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return Double(info.phys_footprint) / 1_048_576
}

private func summary(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    guard let last = sorted.last else { return ["n": 0] }
    let at = { (share: Double) in sorted[Int((Double(sorted.count - 1) * share).rounded())] }
    return ["n": Double(sorted.count), "p50": at(0.5), "p95": at(0.95), "max": last]
}

private final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var waits: [String: [Double]] = [:]
    private var failed: [String] = []
    private var loaded: Set<String> = []
    private var outputs: [String: Int] = [:]

    func start() {
        lock.withLock { recording = true }
    }

    func stop() {
        lock.withLock { recording = false }
    }

    func wait(_ name: String, since due: Double) {
        let wait = (now() - due) * 1000
        lock.withLock {
            if recording {
                waits[name, default: []].append(wait)
            }
        }
    }

    func event(_ name: String, _ event: RuntimeEvent) {
        lock.withLock {
            switch event {
            case .loaded: loaded.insert(name)
            case let .failed(reason): failed.append("\(name): \(reason)")
            case .output: if recording {
                    outputs[name, default: 0] += 1
                }
            case .surface, .call: break
            }
        }
    }

    var allWaits: [String: [Double]] {
        lock.withLock { waits }
    }

    var outputCounts: [String: Int] {
        lock.withLock { outputs }
    }

    var failures: [String] {
        lock.withLock { failed }
    }

    func isLoaded(_ name: String) -> Bool {
        lock.withLock { loaded.contains(name) }
    }
}

private struct Bench {
    let hub = StateHub(sources: [:])
    let record = Record()

    func load(_ directory: URL, _ kind: PluginKind, settings: JSON = .object([:])) throws -> PluginRuntime {
        let bundle = try PluginBundle.load(directory, origin: .user, capabilities: Capability.names())
        let shown: [String: ShownSurface] = kind == .menu || kind == .service ? [:] : [SurfaceAddress.main: ShownSurface(focused: display.id)]
        let name = "\(bundle.manifest.id)/\(kind.rawValue)"
        let record = record
        let theme = try JSON.parse(Data(contentsOf: root.appending(path: "Resources/theme.json")))
        let runtime = PluginRuntime(
            bundle: bundle,
            kind: kind,
            scene: Scene(displays: kind == .service ? [] : [display], shown: shown),
            settings: settings,
            theme: theme,
            hub: hub,
            deliver: { _, event in record.event(name, event) },
            engine: benchEngine,
            transpiler: transpiler,
        )
        runtime.load(Trace("load"))
        for _ in 0..<200 where !record.isLoaded(name) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return runtime
    }

    func loadSet() throws -> [String: PluginRuntime] {
        let set: [(String, PluginKind)] = [
            ("dinky", .service), ("theme", .service), ("dinky", .barWidget), ("front-app", .barWidget),
            ("weather", .barWidget), ("battery", .barWidget), ("clock", .barWidget), ("theme", .menu),
        ]
        var runtimes: [String: PluginRuntime] = [:]
        for (id, kind) in set {
            runtimes["\(id)/\(kind.rawValue)"] = try load(gallery.appending(path: "sndrgrdn.\(id)"), kind)
        }
        let busy = root.appending(path: "scripts/bench/plugins/bench.busy")
        runtimes["busy"] = try load(busy, .panel, settings: .object(["nodes": .number(1000), "hz": .number(30)]))
        return runtimes
    }

    func drive(_ runtimes: [String: PluginRuntime]) throws -> Driver {
        let clock = try #require(runtimes["clock/bar-widget"])
        let weather = try #require(runtimes["weather/bar-widget"])
        let battery = try #require(runtimes["battery/bar-widget"])
        let dinky = try #require(runtimes["dinky/service"])
        let driver = Driver()
        driver.every { publish("clock", .object(["epoch": .number((Date().timeIntervalSince1970 * 1000).rounded())]), to: [clock, weather]) }
        var percent = 50
        driver.every {
            percent = percent % 90 + Int.random(in: 1...9)
            publish("battery", .object(["present": .bool(true), "percent": .number(Double(percent)), "source": .string("battery")]), to: [battery])
        }
        driver.every { dinky.call("focus-changed", []) { _ in _ = 0 } }
        return driver
    }

    func runaway() async throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gary-bench-runaway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"{"schemaVersion":1,"id":"\#(runawayID)","name":"Runaway","version":"0.1.0","kinds":["bar-widget"],"entryPoints":{"bar-widget":"main.js"}}"#
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))
        let source = #"export default { render() { return { type: "text", text: "spin" }; }, onAction() { for (;;) {} } };"#
        try Data(source.utf8).write(to: directory.appending(path: "main.js"))
        let runaway = try load(directory, .barWidget)
        let started = now()
        runaway.perform("spin", .null)
        while !record.failures.contains(where: { $0.hasPrefix(runawayID) }), now() - started < 5 {
            try await Task.sleep(for: .milliseconds(1))
        }
        return ["stopped": record.failures.contains { $0.hasPrefix(runawayID) && $0.contains(stopMessage) }, "afterMs": (now() - started) * 1000]
    }

    func publish(_ topic: String, _ value: JSON, to runtimes: [PluginRuntime]) {
        let due = now()
        hub.publish(.capability(topic), value, Trace(topic, start: due))
        for runtime in runtimes {
            let name = runtime.bundle.manifest.id.rawValue
            runtime.queue.async { record.wait(name, since: due) }
        }
    }
}

private final class Driver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bench.driver", qos: .userInitiated)
    private var running = true

    func every(_ body: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 150...250))) { [self] in
            guard running else { return }
            body()
            every(body)
        }
    }

    func stop() {
        queue.sync { running = false }
    }
}

struct EngineBench {
    @Test(.enabled(if: environment["GARY_ENGINE_BENCH"] != nil))
    func `bar widgets wait behind a busy panel`() async throws {
        let seconds = Double(environment["GARY_ENGINE_BENCH"] ?? "60") ?? 60
        let baseline = footprint()
        let bench = Bench()
        let runtimes = try bench.loadSet()
        let driver = try bench.drive(runtimes)
        try await Task.sleep(for: .seconds(5))
        bench.record.start()
        var memory: [Double] = []
        for _ in 0..<Int(seconds) {
            try await Task.sleep(for: .seconds(1))
            memory.append(footprint() - baseline)
        }
        bench.record.stop()
        driver.stop()
        let runaway = try await bench.runaway()
        let waits = bench.record.allWaits
        let failures = bench.record.failures
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        let result: [String: Any] = [
            "side": environment["BENCH_SIDE"] ?? "",
            "seconds": seconds,
            "load1": load[0],
            "widgets": summary(waits.values.flatMap(\.self)),
            "perWidget": waits.mapValues(summary),
            "memoryMB": summary(memory),
            "failures": failures,
            "outputs": bench.record.outputCounts,
            "falseKills": failures.count { $0.contains(stopMessage) && !$0.hasPrefix(runawayID) },
            "runaway": runaway.merging(["othersRunning": runtimes.values.allSatisfy { runtime in runtime.queue.sync { runtime.isRunning } }]) { $1 },
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("engine_bench " + String(decoding: data, as: UTF8.self))
        for runtime in runtimes.values {
            runtime.stop()
        }
    }
}
