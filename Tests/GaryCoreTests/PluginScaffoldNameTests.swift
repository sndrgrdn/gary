import Foundation
@testable import GaryCore
import Testing

struct PluginScaffoldNameTests {
    @Test func `the display name title cases the words of the last id segment`() throws {
        let cases = [("acme.hello-world", "Hello World"), ("acme.tools.disk-usage-2", "Disk Usage 2"), ("a.b", "B")]
        for (raw, name) in cases {
            #expect(try PluginScaffold.displayName(#require(PluginID(raw))) == name)
        }
    }
}
