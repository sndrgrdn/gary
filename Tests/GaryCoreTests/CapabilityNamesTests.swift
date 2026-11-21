@testable import GaryCore
import Testing

struct CapabilityNamesTests {
    @Test func `uses names the AP is and topics names the publishers`() throws {
        let names = try CapabilityNames([
            CapabilityDeclaration("exec", installs: true, publishes: false),
            CapabilityDeclaration("clock", installs: false, publishes: true),
            CapabilityDeclaration("now-playing", installs: true, publishes: true),
            CapabilityDeclaration("wifi2", installs: false, publishes: true),
        ])
        #expect(names.uses == ["exec", "now-playing"])
        #expect(names.topics == ["clock", "now-playing", "wifi2"])
    }

    @Test func `names are lowercase words that cannot be mistaken for plugin IDs`() {
        for name in ["", "Exec", "now playing", "acme.counter", "-exec", "2fa", "café"] {
            #expect(throws: CapabilityError.invalidName(name)) { try CapabilityNames([CapabilityDeclaration(name, installs: true, publishes: false)])
            }
        }
    }

    @Test func `a name is registered once even when one entry installs and the other publishes`() {
        #expect(throws: CapabilityError.duplicateName("audio")) { try CapabilityNames([
            CapabilityDeclaration("audio", installs: true, publishes: false),
            CapabilityDeclaration("exec", installs: true, publishes: false),
            CapabilityDeclaration("audio", installs: false, publishes: true),
        ]) }
    }

    @Test func `a capability must install an API or publish A topic`() {
        #expect(throws: CapabilityError.noEffect("idle")) { try CapabilityNames([CapabilityDeclaration("idle", installs: false, publishes: false)]) }
    }
}
