import AppKit
import Foundation
@testable import gary
import Testing

@MainActor
struct NodeImagesTests {
    private struct Purgeable {
        let volatile: Int
        let nonvolatile: Int
    }

    private func purgeable() -> Purgeable {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { pointer in
            pointer
                .withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Purgeable(volatile: Int(info.ledger_purgeable_volatile), nonvolatile: Int(info.ledger_purgeable_nonvolatile))
    }

    @Test func `decoded pixels count toward memory only while an image shows them and show again without decoding`() throws {
        let side = 1024
        let bytes = side * side * 4
        var draws = 0
        let before = purgeable()
        let bitmap = try #require(Bitmap(width: side, height: side) { context in
            draws += 1
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        })
        #expect(purgeable().volatile - before.volatile >= bytes)
        autoreleasepool {
            let image = bitmap.image()
            #expect(purgeable().nonvolatile - before.nonvolatile >= bytes)
            let same = bitmap.image() === image
            #expect(same)
        }
        #expect(purgeable().volatile - before.volatile >= bytes)
        #expect(purgeable().nonvolatile - before.nonvolatile < bytes)
        let again = try #require(bitmap.image()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = NSBitmapImageRep(cgImage: again).colorAt(x: side / 2, y: side / 2)
        #expect((pixel?.redComponent ?? 0) > 0.8 && (pixel?.greenComponent ?? 1) < 0.3)
        #expect(draws == 1)
    }
}
