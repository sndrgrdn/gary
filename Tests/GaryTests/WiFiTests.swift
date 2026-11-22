import CoreWLAN
@testable import gary
import Testing

struct WiFiTests {
    @Test func `known networks are the named networks in the Wi-Fi configuration`() {
        let home = CWMutableNetworkProfile()
        home.ssidData = Data("Home".utf8)
        let configuration = CWMutableConfiguration()
        configuration.networkProfiles = NSOrderedSet(array: [home, CWMutableNetworkProfile()])
        #expect(knownNetworks(configuration) == ["Home"])
        #expect(knownNetworks(nil).isEmpty)
    }
}
