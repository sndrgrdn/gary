import CoreGraphics
import Foundation
@testable import gary
import Testing

struct WindowInfoTests {
    private let bounds = CGRect(x: 120, y: 0, width: 36, height: 24)

    private func entry(
        id: Int? = 42,
        owner: Int? = 501,
        ownerName: String? = nil,
        layer: Int? = 24,
        bounds: NSDictionary? = nil,
    ) -> NSDictionary {
        let entry = NSMutableDictionary()
        entry[kCGWindowNumber as String] = id
        entry[kCGWindowOwnerPID as String] = owner
        entry[kCGWindowOwnerName as String] = ownerName
        entry[kCGWindowLayer as String] = layer
        entry[kCGWindowBounds as String] = bounds
        return entry
    }

    @Test func `parses the number owner owner name layer and bounds of a window list entry`() {
        let info = WindowInfo(entry(ownerName: "Window Server", bounds: bounds.dictionaryRepresentation as NSDictionary))
        #expect(info == WindowInfo(id: 42, owner: 501, ownerName: "Window Server", layer: 24, bounds: bounds))
    }

    @Test func `keeps an entry without an owner name or bounds`() {
        #expect(WindowInfo(entry()) == WindowInfo(id: 42, owner: 501, ownerName: nil, layer: 24, bounds: nil))
    }

    @Test func `rejects an entry without a number owner or layer`() {
        #expect(WindowInfo(entry(id: nil)) == nil)
        #expect(WindowInfo(entry(owner: nil)) == nil)
        #expect(WindowInfo(entry(layer: nil)) == nil)
    }
}
