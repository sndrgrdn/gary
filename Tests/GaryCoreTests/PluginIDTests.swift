import Foundation
@testable import GaryCore
import Testing

struct PluginIDTests {
    @Test func `the built in ids parse as reserved plugin ids`() throws {
        let onboarding = try #require(PluginID("gary.onboarding"))
        #expect(PluginID.onboarding == onboarding)
        #expect(PluginID.onboarding.isReserved)
        #expect(ShellConfig.defaults.bar[.right] == ["gary.battery", "gary.clock"].compactMap(PluginID.init))
    }

    @Test func `ids order by their raw value`() throws {
        let ids = try ["acme.b", "acme.a-z", "acme.a"].map { try #require(PluginID($0)) }
        #expect(ids.sorted().map(\.rawValue) == ["acme.a", "acme.a-z", "acme.b"])
    }
}
