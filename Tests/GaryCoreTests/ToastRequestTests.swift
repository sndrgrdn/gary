@testable import GaryCore
import Testing

struct ToastRequestTests {
    private func toast(_ fields: [String: JSON]) throws -> ToastRequest {
        try ToastRequest.parse(HostCall(api: nil, method: "toast", arguments: [.object(fields)]))
    }

    @Test func `a toast needs A title and lasts five seconds unless it says otherwise`() throws {
        #expect(try toast(["title": "Saved"]) == ToastRequest(title: "Saved", timeout: 5))
        #expect(try toast(["title": "Battery", "body": "12%", "icon": "battery.25percent", "timeout": 2])
            == ToastRequest(title: "Battery", body: "12%", icon: "battery.25percent", timeout: 2))
        #expect(try toast(["title": "Stays", "body": .null, "timeout": 0]) == ToastRequest(title: "Stays", timeout: nil))
    }

    @Test func `rejects A missing title a negative timeout and unknown fields`() {
        #expect(throws: ArgumentError("host.toast: title must be a string")) { try toast(["body": "no title"]) }
        #expect(throws: ArgumentError("host.toast: timeout must be 0 or more seconds")) { try toast(["title": "a", "timeout": -1]) }
        #expect(throws: ArgumentError("host.toast: unknown field \"message\"; use title, body, icon, timeout")) {
            try toast(["title": "a", "message": "b"])
        }
        #expect(throws: ArgumentError("host.toast: the argument must be an object")) {
            try ToastRequest.parse(HostCall(api: nil, method: "toast", arguments: [.string("hi")]))
        }
    }
}
