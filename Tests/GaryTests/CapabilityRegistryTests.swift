@testable import gary
import Testing

struct CapabilityRegistryTests {
    @Test func `each capability has A lowercase name that cannot be mistaken for A plugin ID`() {
        for capability in Capability.all {
            #expect(capability.name.firstMatch(of: #/^[a-z][a-z0-9-]*$/#) != nil, "\(capability.name)")
        }
    }

    @Test func `each capability is registered once`() {
        let names = Capability.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func `each capability installs an API or publishes A topic`() {
        for capability in Capability.all {
            #expect(capability.install != nil || capability.topic != nil, "\(capability.name)")
        }
    }
}
