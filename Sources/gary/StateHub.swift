import Foundation
import GaryCore

protocol Subscriber: AnyObject {
    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace)
}

final class StateHub {
    private let lock = NSLock()
    private var latest: [Topic: JSON] = [:]
    private var subscribers: [Topic: [ObjectIdentifier: Subscriber]] = [:]

    func publish(_ topic: Topic, _ value: JSON, _ trace: Trace) {
        let targets: [Subscriber] = lock.withLock {
            guard latest[topic] != value else { return [] }
            latest[topic] = value
            return Array(subscribers[topic, default: [:]].values)
        }
        for subscriber in targets { subscriber.receive(topic, value, trace) }
    }

    func subscribe(_ subscriber: Subscriber, to topics: [Topic]) -> [Topic: JSON] {
        lock.withLock {
            for topic in topics { subscribers[topic, default: [:]][ObjectIdentifier(subscriber)] = subscriber }
            return latest.filter { topics.contains($0.key) }
        }
    }

    func unsubscribe(_ subscriber: Subscriber) {
        lock.withLock {
            for topic in subscribers.keys { subscribers[topic]?[ObjectIdentifier(subscriber)] = nil }
        }
    }
}
