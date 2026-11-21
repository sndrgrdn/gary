import Foundation
import GaryCore
import IOKit.ps

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
