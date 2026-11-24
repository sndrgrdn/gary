@testable import GaryCore
import Testing

struct ToastRequestTests {
    private func toast(_ fields: [String: JSON]) throws -> ToastRequest {
        try ToastRequest.parse(HostCall(api: nil, method: "toast", arguments: [.object(fields)]))
    }

    @Test func `a toast needs A title and lasts five seconds unless it says otherwise`() throws {
        #expect(try toast(["title": "Saved"]) == ToastRequest(title: "Saved", timeout: 5))
        #expect(try toast(["title": "Battery", "body": "12%", "icon": "battery.25percent", "timeout": 2])
            == ToastRequest(title: "Battery", body: "12%", icon: .symbol("battery.25percent"), timeout: 2))
        #expect(try toast(["title": "Stays", "body": .null, "timeout": 0]) == ToastRequest(title: "Stays", timeout: nil))
    }

    @Test func `a glyph replaces the symbol and may name a theme font`() throws {
        #expect(try toast(["title": "Saved", "glyph": "\u{F0193}"]) == ToastRequest(title: "Saved", icon: .glyph("\u{F0193}", font: nil)))
        #expect(try toast(["title": "Saved", "glyph": "\u{F0193}", "font": "icon"])
            == ToastRequest(title: "Saved", icon: .glyph("\u{F0193}", font: "icon")))
        #expect(throws: ArgumentError("host.toast: set icon or glyph, not both")) { try toast(["title": "a", "icon": "clock", "glyph": "x"]) }
        #expect(throws: ArgumentError("host.toast: font needs a glyph")) { try toast(["title": "a", "icon": "clock", "font": "icon"]) }
        #expect(throws: ArgumentError("host.toast: glyph must be a string")) { try toast(["title": "a", "glyph": 1]) }
    }

    @Test func `rejects A missing title a negative timeout and unknown fields`() {
        #expect(throws: ArgumentError("host.toast: title must be a string")) { try toast(["body": "no title"]) }
        #expect(throws: ArgumentError("host.toast: timeout must be 0 or more seconds")) { try toast(["title": "a", "timeout": -1]) }
        #expect(throws: ArgumentError("host.toast: unknown field \"message\"; use title, body, icon, glyph, font, timeout")) {
            try toast(["title": "a", "message": "b"])
        }
        #expect(throws: ArgumentError("host.toast: the argument must be an object")) {
            try ToastRequest.parse(HostCall(api: nil, method: "toast", arguments: [.string("hi")]))
        }
    }
}
