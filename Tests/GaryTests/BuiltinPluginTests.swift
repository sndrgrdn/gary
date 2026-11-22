import Foundation
@testable import gary
import GaryCore
import Testing

struct BuiltinPluginTests {
    @Test func `every bundled plugin loads in the gary namespace`() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/plugins").standardizedFileURL
        let catalog = PluginCatalog.scan(builtin: folder, user: nil, packages: [], capabilities: Capability.names())
        #expect(catalog.problems.isEmpty)
        let folders = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        #expect(catalog.plugins.count == folders.count)
        #expect(!catalog.sortedIDs.contains { !$0.isReserved })
    }
}
