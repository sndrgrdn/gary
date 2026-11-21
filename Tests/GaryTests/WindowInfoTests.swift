import CoreGraphics
import Foundation
@testable import gary
import Testing

struct WindowInfoTests {
    private let bounds = CGRect(x: 120, y: 0, width: 36, height: 24)

    private func entry(id: Int? = 42, owner: Int? = 501, layer: Int? = 24, bounds: NSDictionary? = nil) -> NSDictionary {
        let entry = NSMutableDictionary()
        entry[kCGWindowNumber as String] = id
        entry[kCGWindowOwnerPID as String] = owner
        entry[kCGWindowLayer as String] = layer
        entry[kCGWindowBounds as String] = bounds
        return entry
    }

    @Test func `parses the number owner layer and bounds of a window list entry`() {
        let info = WindowInfo(entry(bounds: bounds.dictionaryRepresentation as NSDictionary))
        #expect(info == WindowInfo(id: 42, owner: 501, layer: 24, bounds: bounds))
    }

    @Test func `keeps an entry without bounds`() {
        #expect(WindowInfo(entry()) == WindowInfo(id: 42, owner: 501, layer: 24, bounds: nil))
    }

    @Test func `rejects an entry without a number owner or layer`() {
        #expect(WindowInfo(entry(id: nil)) == nil)
        #expect(WindowInfo(entry(owner: nil)) == nil)
        #expect(WindowInfo(entry(layer: nil)) == nil)
    }
}
