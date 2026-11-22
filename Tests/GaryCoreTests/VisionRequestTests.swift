import Foundation
@testable import GaryCore
import Testing

private func parse(_ method: String, _ arguments: JSON...) throws -> VisionRequest {
    try VisionRequest.parse(HostCall(api: "vision", method: method, arguments: arguments), home: "/Users/gary", folder: "/Users/gary/plugins/ocr")
}

struct VisionRequestTests {
    @Test func `read text and read codes take an image path or A screen area`() throws {
        #expect(try parse("readText", .string("~/shot.png")) == .readText(.file("/Users/gary/shot.png")))
        #expect(try parse("readText", .string("fixtures/a.png")) == .readText(.file("/Users/gary/plugins/ocr/fixtures/a.png")))
        #expect(try parse("readText", .object(["window": .number(9)])) == .readText(.screen(.window(9))))
        #expect(throws: ArgumentError.self) { try parse("readText", .string("")) }
        #expect(throws: ArgumentError.self) { try parse("readText", .number(3)) }
        #expect(throws: ArgumentError.self) { try parse("readText") }
        #expect(try parse("readCodes", .string("/tmp/qr.png")) == .readCodes(.file("/tmp/qr.png")))
        #expect(try parse("readCodes", .object([:])) == .readCodes(.screen(.display(nil))))
        #expect(throws: ArgumentError("host.vision.translate is not a method")) { try parse("translate", .string("/a.png")) }
    }
}
