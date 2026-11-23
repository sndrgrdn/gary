import Foundation
import GaryCore
import GaryPrivate
@preconcurrency import JavaScriptCore

final nonisolated class PluginEngine: @unchecked Sendable {
    static let timeLimit = 0.1
    static let quiet: TimeInterval = 10

    let queue = DispatchQueue(label: "gary.engine", qos: .userInitiated)
    private let machine: JSVirtualMachine = .init()
    private let effectScript: URL
    private var effectLibrary: JSValue?
    private let entry = NSLock()
    private let state = NSLock()
    private var current: (plugin: PluginID, started: Duration)?
    private var stopped = false
    private var dropping: DispatchWorkItem?

    init(effect: URL = Paths.effect) {
        effectScript = effect
        if let context = JSContext(virtualMachine: machine), !limit(context.jsGlobalContextRef) {
            log("no script time limit on this system")
        }
    }

    func makeContext() -> JSContext? {
        JSContext(virtualMachine: machine)
    }

    func effect() throws -> JSValue {
        if let effectLibrary {
            return effectLibrary
        }
        let paused = state.withLock { current.take() }
        let loading = cpuTime()
        defer { state.withLock { current = paused.map { ($0.plugin, $0.started + cpuTime() - loading) } } }
        guard let context = JSContext(virtualMachine: machine) else { throw RenderError("cannot load gary:effect: no JavaScript context") }
        context.name = "gary:effect"
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() ?? "unknown exception" }
        do {
            try context.evaluateScript(String(contentsOf: effectScript, encoding: .utf8), withSourceURL: effectScript)
        } catch {
            throw RenderError("cannot load gary:effect from \(effectScript.path): \(error.localizedDescription)")
        }
        let library = context.objectForKeyedSubscript("GaryEffect")?.objectForKeyedSubscript("forPlugin")
        guard failure == nil, let library, library.isObject else {
            throw RenderError("cannot load gary:effect from \(effectScript.path): \(failure ?? "no forPlugin")")
        }
        context.exceptionHandler = { _, value in log("gary:effect: \(value?.toString() ?? "unknown exception")") }
        effectLibrary = library
        return library
    }

    func dropCodeWhenQuiet() {
        let work = DispatchWorkItem { [weak self] in self?.dropCode() }
        state.withLock {
            dropping?.cancel()
            dropping = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.quiet, execute: work)
    }

    func dropCode() {
        let dropped = entry.withLock { JSContext(virtualMachine: machine).map { gary_drop_compiled_code($0.jsGlobalContextRef) } }
        if dropped == false {
            _ = Self.cannotDropCode
        }
    }

    private static let cannotDropCode: Void = {
        let missing = missingSymbols([.lockEngine, .unlockEngine, .deleteAllCode, .collectGarbage, .releaseFreeMemory])
        log("cannot drop plugin bytecode: \(missing.joined(separator: ", ")) is missing from JavaScriptCore on this macOS")
    }()

    func run(_ plugin: PluginID, in context: JSContext, _ body: () -> JSValue?) throws -> JSValue? {
        entry.lock()
        defer { entry.unlock() }
        let result = timed(plugin, body)
        guard result.stopped else { return result.value }
        _ = timed(plugin) { context.evaluateScript("0") }
        throw RenderError("stopped after running longer than \(Int(Self.timeLimit * 1000)) ms")
    }

    private func timed(_ plugin: PluginID, _ body: () -> JSValue?) -> (value: JSValue?, stopped: Bool) {
        state.withLock {
            current = (plugin, cpuTime())
            stopped = false
        }
        let value = body()
        return state.withLock {
            current = nil
            return (value, stopped)
        }
    }

    private func shouldStop(_ context: JSContextRef) -> Bool {
        let stop = state.withLock {
            guard let current, cpuTime() - current.started >= .seconds(Self.timeLimit) else { return false }
            stopped = true
            return true
        }
        if !stop {
            limit(JSContextGetGlobalContext(context))
        }
        return stop
    }

    @discardableResult
    private func limit(_ context: JSGlobalContextRef) -> Bool {
        gary_script_time_limit(context, Self.timeLimit, { context, info in
            guard let info else { return false }
            return Unmanaged<PluginEngine>.fromOpaque(info).takeUnretainedValue().shouldStop(context)
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}

private nonisolated func cpuTime() -> Duration {
    .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
}
