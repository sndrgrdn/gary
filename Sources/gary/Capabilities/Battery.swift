import Foundation
import GaryCore
import IOKit.ps

extension Capability {
    static let battery = Capability(name: "battery", topic: { BatteryTopic($0) })
}

private final class BatteryTopic {
    private let publish: (JSON, Trace) -> Void
    private var observation: Observation?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            Unmanaged<BatteryTopic>.fromOpaque(context!).takeUnretainedValue().send(Trace("battery"))
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observation = Observation { CFRunLoopSourceInvalidate(source) }
        send(Trace("battery-start"))
    }

    private func send(_ trace: Trace) {
        publish(Self.read(), trace)
    }

    private static func read() -> JSON {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let acPower = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return snapshot(percent: min(100, current * 100 / maximum), charging: description[kIOPSIsChargingKey] as? Bool ?? false, ac: acPower)
        }
        return snapshot(percent: nil, charging: false, ac: true)
    }

    private static func snapshot(percent: Int?, charging: Bool, ac: Bool) -> JSON {
        .object([
            "present": .bool(percent != nil),
            "percent": percent.map { .number(Double($0)) } ?? .null,
            "charging": .bool(charging),
            "source": .string(ac ? "ac" : "battery"),
        ])
    }
}
