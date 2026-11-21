import Testing
@testable import GaryCore

struct CapabilityNamesTests {
    @Test func usesAreTheRegisteredNames() throws {
        #expect(try CapabilityNames(uses: ["exec", "files", "now-playing", "wifi2"]).uses == ["exec", "files", "now-playing", "wifi2"])
    }

    @Test func namesAreLowercaseWordsThatCannotBeMistakenForPluginIDs() {
        for name in ["", "Exec", "now playing", "acme.counter", "-exec", "2fa", "café"] {
            #expect(throws: CapabilityError.invalidName(name)) { try CapabilityNames(uses: [name]) }
        }
    }

    @Test func aNameIsRegisteredOnce() {
        #expect(throws: CapabilityError.duplicateName("exec")) { try CapabilityNames(uses: ["exec", "files", "exec"]) }
    }
}
