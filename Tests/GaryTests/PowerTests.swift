import Foundation
@testable import gary
import Testing

struct PowerTests {
    @Test func `host power offers each action its types declare`() async throws {
        let harness = try Harness(widget(setup: "count = Object.keys(host.power).sort().join(\",\");"))
        #expect(try await harness.text() == "lock,logOut,restart,shutDown,sleep")
        let declared = Capability.power.types.firstMatch(of: #/power: \{(.*)\}/#).map { String($0.1) } ?? ""
        #expect(declared.matches(of: #/(\w+)\(/#).map { String($0.1) }.sorted() == ["lock", "logOut", "restart", "shutDown", "sleep"])
        harness.runtime.stop()
    }
}
