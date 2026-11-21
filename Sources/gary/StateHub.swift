import Foundation
import GaryCore

protocol Subscriber: AnyObject {
    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace)
}

final class StateHub {
    var demandChanged: ((Topic) -> Void)?
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
        let (values, started): ([Topic: JSON], [Topic]) = lock.withLock {
            let started = topics.filter { subscribers[$0, default: [:]].isEmpty }
            for topic in topics { subscribers[topic, default: [:]][ObjectIdentifier(subscriber)] = subscriber }
            return (latest.filter { topics.contains($0.key) }, started)
        }
        for topic in started { demandChanged?(topic) }
        return values
    }

    func unsubscribe(_ subscriber: Subscriber) {
        let stopped: [Topic] = lock.withLock {
            var stopped: [Topic] = []
            for topic in subscribers.keys where subscribers[topic]?.removeValue(forKey: ObjectIdentifier(subscriber)) != nil {
                if subscribers[topic]!.isEmpty { stopped.append(topic) }
            }
            return stopped
        }
        for topic in stopped { demandChanged?(topic) }
    }

    func isDemanded(_ topic: Topic) -> Bool {
        lock.withLock { !(subscribers[topic]?.isEmpty ?? true) }
    }
}
