import Foundation
import GaryCore

nonisolated protocol Subscriber: AnyObject, Sendable {
    var slot: SlotKey { get }
    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace)
}

nonisolated protocol TopicFeed: AnyObject {}

typealias TopicSource = @MainActor @Sendable (@escaping @Sendable (JSON, Trace) -> Void) -> any TopicFeed

final nonisolated class StateHub: @unchecked Sendable {
    private let sources: [Topic: TopicSource]
    private let lock = NSLock()
    private var latest: [Topic: JSON] = [:]
    private var subscribers: [Topic: [ObjectIdentifier: Subscriber]] = [:]
    private var live: Set<Topic> = []
    private var running: [Topic: any TopicFeed] = [:]
    private var replay: (topics: Set<Topic>, plugin: PluginID?)?
    private var reconciling: [(Topic, TopicSource)] = []

    init(sources: [Topic: TopicSource]) {
        self.sources = sources
    }

    func publish(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        let targets: [Subscriber] = lock.withLock {
            guard sources[topic] == nil || live.contains(topic), latest[topic] != value else { return [] }
            guard let replay, replay.topics.contains(topic) else {
                latest[topic] = value
                return Array(subscribers[topic, default: [:]].values)
            }
            guard let plugin = replay.plugin else { return [] }
            latest[topic] = value
            return subscribers[topic, default: [:]].values.filter { $0.slot.id != plugin }
        }
        deliver(topic, value, trace, to: targets)
    }

    func replay(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        let targets: [Subscriber] = lock.withLock {
            guard let replay, replay.topics.contains(topic) else { return [] }
            guard let plugin = replay.plugin else {
                latest[topic] = value
                return Array(subscribers[topic, default: [:]].values)
            }
            return subscribers[topic, default: [:]].values.filter { $0.slot.id == plugin }
        }
        deliver(topic, value, trace, to: targets)
    }

    func traceLatest(_ trace: Trace) {
        let values = lock.withLock { latest.map { ($0.key, $0.value, Array(subscribers[$0.key, default: [:]].values)) } }
        for (topic, value, targets) in values.sorted(by: { $0.0.description < $1.0.description }) {
            note(topic, value, trace, targets)
        }
    }

    private func note(_ topic: Topic, _ value: JSON, _ trace: Trace, _ targets: [Subscriber]) {
        guard TraceLog.isOn else { return }
        var fields: [String: JSON] = [
            "topic": .string(topic.description),
            "subscribers": .array(targets.map { TraceLog.slot($0.slot) }),
            "bytes": .number(Double(value.text.utf8.count)),
        ]
        if TraceLog.keepsValues {
            fields["value"] = value
        }
        TraceLog.note("publish", trace.id, fields)
    }

    private func deliver(_ topic: Topic, _ value: JSON, _ trace: Trace, to targets: [Subscriber]) {
        note(topic, value, trace, targets)
        for subscriber in targets {
            subscriber.receive(topic, value, trace)
        }
    }

    @MainActor
    func beginReplay(_ topics: Set<Topic>, to plugin: PluginID?) -> Bool {
        let started = lock.withLock {
            guard replay == nil else { return false }
            replay = (topics, plugin)
            return true
        }
        guard started, plugin == nil else { return started }
        for topic in topics where running.removeValue(forKey: topic) != nil {
            log("topic \(topic): stopped for a replay")
        }
        return true
    }

    @MainActor
    func endReplay() {
        guard let ended = lock.withLock({ replay.take() }) else { return }
        guard let plugin = ended.plugin else {
            lock.withLock {
                for topic in ended.topics {
                    latest[topic] = nil
                }
            }
            reconcile(Array(ended.topics))
            return
        }
        let resumed = lock.withLock {
            ended.topics.compactMap { topic in
                latest[topic].map { (topic, $0, subscribers[topic, default: [:]].values.filter { $0.slot.id == plugin }) }
            }
        }
        for (topic, value, targets) in resumed {
            deliver(topic, value, Trace("replay-end"), to: targets)
        }
    }

    func subscribe(_ subscriber: Subscriber, to topics: [Topic]) -> [Topic: JSON] {
        defer { reconcile(topics) }
        return lock.withLock {
            for topic in topics {
                subscribers[topic, default: [:]][ObjectIdentifier(subscriber)] = subscriber
            }
            return latest.filter { topics.contains($0.key) }
        }
    }

    func unsubscribe(_ subscriber: Subscriber) {
        let left: [Topic] = lock.withLock {
            subscribers.keys.filter { subscribers[$0]?.removeValue(forKey: ObjectIdentifier(subscriber)) != nil }
        }
        reconcile(left)
    }

    private func reconcile(_ topics: [Topic]) {
        let managed = topics.compactMap { topic in sources[topic].map { (topic, $0) } }
        guard !managed.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            let idle = reconciling.isEmpty
            reconciling += managed
            if idle {
                reconcileNext()
            }
        }
    }

    @MainActor private func reconcileNext() {
        guard let (topic, source) = reconciling.first else { return }
        let (wanted, replayed) = lock.withLock {
            let wanted = !(subscribers[topic]?.isEmpty ?? true)
            let replayed = replay.map { $0.plugin == nil && $0.topics.contains(topic) } ?? false
            if wanted {
                live.insert(topic)
            }
            return (wanted, replayed)
        }
        if wanted, !replayed, running[topic] == nil {
            let started = now()
            running[topic] = source { [weak self] value, trace in self?.publish(topic, value, trace) }
            log(String(format: "topic %@: started in %.1f ms", topic.description, (now() - started) * 1000))
        } else if !wanted, running[topic] != nil {
            lock.withLock {
                live.remove(topic)
                latest[topic] = nil
            }
            running[topic] = nil
            log("topic \(topic): stopped")
        }
        reconciling.removeFirst()
        guard !reconciling.isEmpty else { return }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [self] in MainActor.assumeIsolated { reconcileNext() } }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
