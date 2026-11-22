@testable import GaryCore
import Testing

struct CapabilityNamesTests {
    @Test func `uses names the AP is and topics names the publishers`() {
        let names = CapabilityNames([
            CapabilityDeclaration("exec", installs: true, publishes: false),
            CapabilityDeclaration("clock", installs: false, publishes: true),
            CapabilityDeclaration("now-playing", installs: true, publishes: true),
            CapabilityDeclaration("wifi2", installs: false, publishes: true),
        ])
        #expect(names.uses == ["exec", "now-playing"])
        #expect(names.topics == ["clock", "now-playing", "wifi2"])
    }
}
