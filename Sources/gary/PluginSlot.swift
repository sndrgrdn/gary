import GaryCore

struct SlotKey: Hashable, CustomStringConvertible {
    let id: PluginID
    let kind: PluginKind
    var description: String {
        "\(id)/\(kind.rawValue)"
    }
}

final class PluginSlot {
    enum Phase {
        case stopped
        case running(PluginRuntime)
        case failed(String)
        case disabled(String)
    }

    let key: SlotKey
    var bundle: PluginBundle
    var phase = Phase.stopped
    var failures = RestartBudget(limit: 5, window: 60)
    var candidate: PluginRuntime?
    var visible = false
    var focused: String?
    var surface: SurfaceSpec?
    var waiters: [(Response) -> Void] = []

    init(key: SlotKey, bundle: PluginBundle) {
        self.key = key
        self.bundle = bundle
    }

    var runtime: PluginRuntime? {
        if case let .running(runtime) = phase {
            return runtime
        }
        return nil
    }

    var disabledReason: String? {
        if case let .disabled(reason) = phase {
            return reason
        }
        return nil
    }

    func answerWaiters(_ response: Response) {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter(response)
        }
    }
}
