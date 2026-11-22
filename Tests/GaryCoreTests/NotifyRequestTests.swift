@testable import GaryCore
import Testing

struct NotifyRequestTests {
    private func post(_ fields: [String: JSON], method: String = "post") throws -> NotifyRequest {
        try NotifyRequest.parse(HostCall(api: "notify", method: method, arguments: [.object(fields)]))
    }

    @Test func `post takes A title and optional subtitle body and sound`() throws {
        #expect(try post(["title": "Battery low"]) == NotifyRequest(title: "Battery low"))
        #expect(try post(["title": "Battery low", "subtitle": "MacBook", "body": "9% left", "sound": true])
            == NotifyRequest(title: "Battery low", subtitle: "MacBook", body: "9% left", sound: true))
    }

    @Test func `rejects A wrong sound unknown fields and other methods`() {
        #expect(throws: ArgumentError("host.notify.post: sound must be true or false")) { try post(["title": "a", "sound": "yes"]) }
        #expect(throws: ArgumentError("host.notify.post: unknown field \"icon\"; use title, subtitle, body, sound")) {
            try post(["title": "a", "icon": "bell"])
        }
        #expect(throws: ArgumentError("host.notify.clear is not a method")) { try post(["title": "a"], method: "clear") }
    }
}
