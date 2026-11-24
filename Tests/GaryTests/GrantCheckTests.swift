import Foundation
@testable import gary
@testable import GaryCore
import Testing

@MainActor
private final class Answer {
    var grants: [Permission: Grant]?
}

@MainActor
struct GrantCheckTests {
    @Test func `checks grants without holding the main thread and answers on it with each permission asked for`() async {
        let answer = Answer()
        await withCheckedContinuation { done in
            checkGrants([.accessibility, .screenRecording]) { grants in
                answer.grants = grants
                done.resume()
            }
            #expect(answer.grants == nil)
        }
        #expect(answer.grants.map { Set($0.keys) } == [.accessibility, .screenRecording])
    }

    @Test func `gary doctor reports the grants that Gary checked for each permission an enabled plugin needs`() throws {
        let manifest = try PluginManifest(
            id: #require(PluginID("test.menu")), name: "Menu", version: "1", kinds: [.menu], entryPoints: [.menu: "main.js"],
            keepLoaded: false, subscriptions: [.menu: []], uses: ["power"], hotkeys: [],
        )
        let report = { (grant: Grant) in
            Doctor.report(
                DoctorRuntime(
                    pid: 1,
                    enabled: [manifest],
                    pluginStates: [],
                    themePayload: nil,
                    grants: [.automation: grant, .accessibility: .granted],
                ),
                system: .dark, files: ConfigFolder().files,
            )
        }
        #expect(report(.granted).contains("  ok    Automation granted; needed by power; used by test.menu (power)"))
        #expect(report(.denied)
            .contains("  FAIL  Automation denied; needed by power; used by test.menu (power); run gary permissions request automation"))
    }
}
