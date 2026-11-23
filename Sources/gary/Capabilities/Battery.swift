import Foundation
import GaryCore
import IOKit.ps

nonisolated extension Capability {
    static let battery = Capability(name: "battery", summary: "Battery percentage, charging state, and power source.", types: """
    declare namespace Gary {
      type Battery = { present: boolean; percent: number | null; charging: boolean; source: "ac" | "battery" }
    }
    """, example: """
    export default {
      render(state) {
        const battery = state.battery;
        if (!battery?.present) return { type: "icon", symbol: "powerplug" };
        return { type: "text", text: `${battery.percent}%`, style: battery.charging ? "good" : battery.percent! < 20 ? "bad" : "default" };
      },
    } satisfies Gary.BarWidget;
    """, topic: CapabilityTopic(type: "Battery") { BatteryTopic($0) })
}

private final class BatteryTopic: TopicFeed {
    private let publish: @Sendable (JSON, Trace) -> Void
    private var observation: Observation?

    init(_ publish: @escaping @Sendable (JSON, Trace) -> Void) {
        self.publish = publish
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryTopic>.fromOpaque(context).takeUnretainedValue().send(Trace("battery"))
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
        let onACPower = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        let battery = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as NSDictionary? }
            .compactMap(InternalBattery.init(description:))
            .first
        guard let battery else { return snapshot(percent: nil, charging: false, onACPower: true) }
        return snapshot(percent: battery.percent, charging: battery.charging, onACPower: onACPower)
    }

    private static func snapshot(percent: Int?, charging: Bool, onACPower: Bool) -> JSON {
        .object([
            "present": .bool(percent != nil),
            "percent": percent.map { .number(Double($0)) } ?? .null,
            "charging": .bool(charging),
            "source": .string(onACPower ? "ac" : "battery"),
        ])
    }
}

nonisolated struct InternalBattery {
    let percent: Int
    let charging: Bool

    init?(description: NSDictionary) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        percent = min(100, current * 100 / maximum)
        charging = description[kIOPSIsChargingKey] as? Bool ?? false
    }
}
