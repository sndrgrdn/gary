import Foundation
@testable import gary
import GaryCore
import Testing

struct SystemStateTests {
    @Test func `reads the Dock autohide setting from a restore file`() throws {
        let hidden = try JSONDecoder().decode(SavedSystemState.self, from: Data(#"{"menuBarHidden": false, "autohide": true}"#.utf8))
        let shown = try JSONDecoder().decode(SavedSystemState.self, from: Data(#"{"menuBarHidden": true, "autohide": false}"#.utf8))
        let untouched = try JSONDecoder().decode(SavedSystemState.self, from: Data(#"{"menuBarHidden": true}"#.utf8))
        #expect(hidden.dockVisibility == .autohide)
        #expect(shown.dockVisibility == .shown)
        #expect(untouched.dockVisibility == nil)
    }

    @Test func `writes the Dock autohide setting to the restore file as a boolean`() throws {
        let shown = try JSON.parse(JSONEncoder().encode(SavedSystemState(dockVisibility: .shown)))
        let hidden = try JSON.parse(JSONEncoder().encode(SavedSystemState(dockVisibility: .autohide)))
        #expect(shown["autohide"] == .bool(false))
        #expect(hidden["autohide"] == .bool(true))
    }
}
