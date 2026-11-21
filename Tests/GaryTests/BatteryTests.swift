import Foundation
@testable import gary
import IOKit.ps
import Testing

struct BatteryTests {
    @Test func `reads the internal battery percentage and charging state`() throws {
        let battery = try #require(InternalBattery(description: [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 4300, kIOPSMaxCapacityKey: 5000, kIOPSIsChargingKey: true,
        ]))
        #expect(battery.percent == 86)
        #expect(battery.charging)
    }

    @Test func `caps the percentage at 100 and reads a battery without a charging flag as not charging`() throws {
        let battery = try #require(InternalBattery(description: [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 105, kIOPSMaxCapacityKey: 100,
        ]))
        #expect(battery.percent == 100)
        #expect(!battery.charging)
    }

    @Test func `ignores power sources that are not a usable internal battery`() {
        #expect(InternalBattery(description: [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100]) == nil)
        #expect(InternalBattery(description: [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 0]) == nil)
        #expect(InternalBattery(description: [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSMaxCapacityKey: 100]) == nil)
    }
}
