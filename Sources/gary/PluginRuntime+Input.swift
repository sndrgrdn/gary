import Foundation
import GaryCore

nonisolated extension PluginRuntime {
    func perform(_ action: String, _ payload: JSON, origin: CGRect? = nil) {
        dispatch("onAction", [.string(action), payload], Trace("action"), origin: origin)
    }

    func key(_ key: String, unhandled: @escaping @MainActor @Sendable () -> Void) {
        dispatch("onKey", [.string(key)], Trace("key"), unhandled: unhandled)
    }

    func scroll(_ event: JSON, action: String? = nil, origin: CGRect? = nil) {
        var fields = event.object ?? [:]
        fields["action"] = action.map(JSON.string)
        dispatch("onScroll", [.object(fields)], Trace("scroll"), origin: origin)
    }

    func hotkey(_ id: String) {
        dispatch("onHotkey", [.string(id)], Trace("hotkey"))
    }

    func mediaKey(_ event: JSON) {
        dispatch("onMediaKey", [event], Trace("mediakey"))
    }

    private func dispatch(
        _ handler: String,
        _ arguments: [JSON],
        _ trace: Trace,
        origin: CGRect? = nil,
        unhandled: (@MainActor @Sendable () -> Void)? = nil,
    ) {
        onQueue { $0.handle(handler, arguments, trace, origin: origin, unhandled: unhandled) }
    }
}
