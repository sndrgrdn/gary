@testable import GaryCore
import Testing

struct CapabilityNamesTests {
    @Test func `uses names the AP is and topics names the publishers`() throws {
        let names = try CapabilityNames([("exec", true, false), ("clock", false, true), ("now-playing", true, true), ("wifi2", false, true)])
        #expect(names.uses == ["exec", "now-playing"])
        #expect(names.topics == ["clock", "now-playing", "wifi2"])
    }

    @Test func `names are lowercase words that cannot be mistaken for plugin IDs`() {
        for name in ["", "Exec", "now playing", "acme.counter", "-exec", "2fa", "café"] {
            #expect(throws: CapabilityError.invalidName(name)) { try CapabilityNames([(name, true, false)]) }
        }
    }

    @Test func `a name is registered once even when one entry installs and the other publishes`() {
        #expect(throws: CapabilityError.duplicateName("audio")) { try CapabilityNames([
            ("audio", true, false),
            ("exec", true, false),
            ("audio", false, true),
        ]) }
    }

    @Test func `a capability must install an API or publish A topic`() {
        #expect(throws: CapabilityError.noEffect("idle")) { try CapabilityNames([("idle", false, false)]) }
    }
}
