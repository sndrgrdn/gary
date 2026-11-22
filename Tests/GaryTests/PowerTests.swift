import Foundation
@testable import gary
@testable import GaryCore
import IOKit.pwr_mgt
import Testing

struct PowerTests {
    @Test func `host power offers each action its types declare`() async throws {
        let harness = try Harness(widget(setup: "count = Object.keys(host.power).sort().join(\",\");"))
        #expect(try await harness.text() == "lock,logOut,restart,shutDown,sleep,stayAwake")
        let declared = Capability.power.types.firstMatch(of: #/power: \{([^}]*)\}/#).map { String($0.1) } ?? ""
        #expect(declared.matches(of: #/(\w+)\(/#).map { String($0.1) }.sorted() == ["lock", "logOut", "restart", "shutDown", "sleep", "stayAwake"])
        harness.runtime.stop()
    }

    @Test func `gary permissions lists Automation as needed by power for a plugin that uses it`() throws {
        let manifest = try PluginManifest(
            id: #require(PluginID("test.menu")), name: "Menu", version: "1", kinds: [.menu], entryPoints: [.menu: "main.js"],
            keepLoaded: false, subscriptions: [.menu: []], uses: ["power"], hotkeys: [],
        )
        let need = try #require(PermissionNeed.all(enabled: [manifest], checkGrants: false).first { $0.permission == .automation })
        #expect(need.summary == "needed by power; used by test.menu (power)")
    }

    @Test func `stay awake holds one assertion that the next call replaces and stopping the plugin releases`() async throws {
        let harness = try Harness(
            widget("onAction: function (mode) { try { host.power.stayAwake(mode); count = mode; } catch (e) { count = e.message; } },"),
            id: "test.awake",
        )
        #expect(try await harness.text() == "0")
        harness.runtime.perform("display", .null)
        #expect(try await harness.text() == "display")
        #expect(assertions(named: "Gary: test.awake") == [kIOPMAssertionTypePreventUserIdleDisplaySleep])
        harness.runtime.perform("system", .null)
        #expect(try await harness.text() == "system")
        #expect(assertions(named: "Gary: test.awake") == [kIOPMAssertionTypePreventUserIdleSystemSleep])
        harness.runtime.perform("off", .null)
        #expect(try await harness.text() == "off")
        #expect(assertions(named: "Gary: test.awake").isEmpty)
        harness.runtime.perform("forever", .null)
        #expect(try await harness.text() == "host.power.stayAwake: mode must be \"off\", \"system\", or \"display\"")
        harness.runtime.perform("display", .null)
        #expect(try await harness.text() == "display")
        harness.runtime.stop()
        #expect(harness.runtime.queue.sync { assertions(named: "Gary: test.awake").isEmpty })
    }
}

private func assertions(named name: String) -> [String] {
    var byProcess: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
          let all = byProcess?.takeRetainedValue() as? [NSNumber: [NSDictionary]] else { return [] }
    return (all[NSNumber(value: getpid())] ?? []).filter { $0[kIOPMAssertionNameKey] as? String == name }
        .compactMap { $0[kIOPMAssertionTypeKey] as? String }
}
