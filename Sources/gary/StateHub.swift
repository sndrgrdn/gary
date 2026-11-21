import Foundation
import GaryCore

protocol Subscriber: AnyObject {
    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace)
}

typealias TopicSource = (@escaping (JSON, Trace) -> Void) -> AnyObject

final class StateHub {
    private let sources: [Topic: TopicSource]
    private let lock = NSLock()
    private var latest: [Topic: JSON] = [:]
    private var subscribers: [Topic: [ObjectIdentifier: Subscriber]] = [:]
    private var live: Set<Topic> = []
    private var running: [Topic: AnyObject] = [:]

    init(sources: [Topic: TopicSource]) {
        self.sources = sources
    }

    func publish(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        let targets: [Subscriber] = lock.withLock {
            guard sources[topic] == nil || live.contains(topic), latest[topic] != value else { return [] }
            latest[topic] = value
            return Array(subscribers[topic, default: [:]].values)
        }
        for subscriber in targets {
            subscriber.receive(topic, value, trace)
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
            for (topic, source) in managed {
                let wanted = lock.withLock {
                    let wanted = !(subscribers[topic]?.isEmpty ?? true)
                    if wanted {
                        live.insert(topic)
                    }
                    return wanted
                }
                if wanted, running[topic] == nil {
                    log("topic \(topic): started")
                    running[topic] = source { [weak self] value, trace in self?.publish(topic, value, trace) }
                } else if !wanted, running[topic] != nil {
                    lock.withLock {
                        live.remove(topic)
                        latest[topic] = nil
                    }
                    running[topic] = nil
                    log("topic \(topic): stopped")
                }
            }
        }
    }
}
