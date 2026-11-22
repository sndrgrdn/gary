import Foundation
@testable import GaryCore
import Testing

private let home = "/Users/gary"
private let folder = "/Users/gary/plugins/shot"

private func parse(_ method: String, _ arguments: JSON...) throws -> ScreenRequest {
    try ScreenRequest.parse(HostCall(api: "screen", method: method, arguments: arguments), home: home, folder: folder)
}

private func region(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> JSON {
    .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)])
}

struct ScreenRequestTests {
    @Test func `capture takes A display A window or A region and an optional path and clipboard`() throws {
        #expect(try parse("capture", .object([:])) == .capture(.display(nil), path: nil, clipboard: false))
        #expect(try parse("capture", .object(["display": .string("37D8")])) == .capture(.display("37D8"), path: nil, clipboard: false))
        #expect(try parse("capture", .object(["window": .number(412)]), .object(["clipboard": .bool(true)]))
            == .capture(.window(412), path: nil, clipboard: true))
        #expect(try parse("capture", region(10, 20, 300, 40), .object(["path": .string("~/Pictures/a.png")]))
            == .capture(.region(CGRect(x: 10, y: 20, width: 300, height: 40)), path: "/Users/gary/Pictures/a.png", clipboard: false))
        #expect(try parse("capture", region(0, 0, 1, 1), .object(["path": .string("shots/a.png")]))
            == .capture(.region(CGRect(x: 0, y: 0, width: 1, height: 1)), path: "/Users/gary/plugins/shot/shots/a.png", clipboard: false))
    }

    @Test func `the area that select resolves with captures the same area`() throws {
        for area in [ScreenArea.display("37D8"), .display(nil), .window(7), .region(CGRect(x: 1, y: 2, width: 3, height: 4))] {
            #expect(try parse("capture", area.json) == .capture(area, path: nil, clipboard: false))
        }
        #expect(try parse("select") == .select)
    }

    @Test func `rejects areas that are not one of the three shapes`() {
        for area: JSON in [
            .null, .string("main"), region(0, 0, 0, 10), region(0, 0, 10, -1),
            .object(["x": .number(0), "y": .number(0), "width": .number(10)]),
            .object(["window": .number(1.5)]), .object(["window": .number(-1)]),
            .object(["window": .number(1), "display": .string("37D8")]),
            .object(["display": .number(1)]),
        ] {
            #expect(throws: ArgumentError.self, "\(area)") { try parse("capture", area) }
        }
        #expect(throws: ArgumentError("host.screen.capture: options.clipboard must be true or false")) {
            try parse("capture", .object([:]), .object(["clipboard": .string("yes")]))
        }
        #expect(throws: ArgumentError.self) { try parse("capture", .object([:]), .object(["path": .string("~other/a.png")])) }
        #expect(throws: ArgumentError("host.screen.grab is not a method")) { try parse("grab") }
    }
}
