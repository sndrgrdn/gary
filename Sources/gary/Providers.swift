import AppKit
import GaryCore
import IOKit.ps

protocol Subscriber: AnyObject {
    func receive(_ topic: Topic, _ value: JSON, _ trace: Trace)
}

final class StateHub {
    private let lock = NSLock()
    private var latest: [Topic: JSON] = [:]
    private var subscribers: [Topic: [ObjectIdentifier: Subscriber]] = [:]

    func publish<S: Snapshot>(_ snapshot: S, _ trace: Trace) {
        let value = snapshot.json
        let targets: [Subscriber] = lock.withLock {
            guard latest[S.topic] != value else { return [] }
            latest[S.topic] = value
            return Array(subscribers[S.topic, default: [:]].values)
        }
        for subscriber in targets { subscriber.receive(S.topic, value, trace) }
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

final class ClockProvider {
    private let hub: StateHub
    private var timer: Timer?

    init(hub: StateHub) { self.hub = hub }

    func start() {
        publish(Trace("clock-start"))
        let next = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.publish(Trace("clock")) }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publish(Trace("wake"))
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.publish(Trace("clock-change")) }
    }

    private func publish(_ trace: Trace) {
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        hub.publish(ClockSnapshot(epochMilliseconds: minute * 1000), trace)
    }
}

final class BatteryProvider {
    private let hub: StateHub

    init(hub: StateHub) { self.hub = hub }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            Unmanaged<BatteryProvider>.fromOpaque(context!).takeUnretainedValue().publish(Trace("battery"))
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        publish(Trace("battery-start"))
    }

    private func publish(_ trace: Trace) {
        hub.publish(Self.read(), trace)
    }

    static func read() -> BatterySnapshot {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let acPower = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return BatterySnapshot(
                percent: min(100, current * 100 / maximum),
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                source: acPower ? .ac : .battery
            )
        }
        return BatterySnapshot(percent: nil, charging: false, source: .ac)
    }
}
