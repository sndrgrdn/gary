import Foundation
import GaryCore
import GaryPrivate
import JavaScriptCore

final class PluginEngine: @unchecked Sendable {
    static let timeLimit = 0.1

    private let entry = NSLock()
    private let state = NSLock()
    private var current: (plugin: PluginID, started: ContinuousClock.Instant)?
    private var stopped = false

    func makeContext() -> JSContext? {
        guard let context = JSContext() else { return nil }
        if !limit(context.jsGlobalContextRef) {
            log("no script time limit on this system")
        }
        return context
    }

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
            current = (plugin, .now)
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
            guard let current, current.started.duration(to: .now) >= .seconds(Self.timeLimit) else { return false }
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
