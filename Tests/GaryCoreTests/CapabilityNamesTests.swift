@testable import GaryCore
import Testing

struct CapabilityNamesTests {
    @Test func usesNamesTheAPIsAndTopicsNamesThePublishers() throws {
        let names = try CapabilityNames([("exec", true, false), ("clock", false, true), ("now-playing", true, true), ("wifi2", false, true)])
        #expect(names.uses == ["exec", "now-playing"])
        #expect(names.topics == ["clock", "now-playing", "wifi2"])
    }

    @Test func namesAreLowercaseWordsThatCannotBeMistakenForPluginIDs() {
        for name in ["", "Exec", "now playing", "acme.counter", "-exec", "2fa", "café"] {
            #expect(throws: CapabilityError.invalidName(name)) { try CapabilityNames([(name, true, false)]) }
        }
    }

    @Test func aNameIsRegisteredOnceEvenWhenOneEntryInstallsAndTheOtherPublishes() {
        #expect(throws: CapabilityError.duplicateName("audio")) { try CapabilityNames([("audio", true, false), ("exec", true, false), ("audio", false, true)]) }
    }

    @Test func aCapabilityMustInstallAnAPIOrPublishATopic() {
        #expect(throws: CapabilityError.noEffect("idle")) { try CapabilityNames([("idle", false, false)]) }
    }
}
