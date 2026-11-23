import Foundation
@testable import GaryCore
import Testing

struct FetchRequestTests {
    private let url = URL(string: "https://api.example.com/usage")!

    @Test func `fetch takes A URL and defaults to GET`() throws {
        #expect(try FetchRequest.parse([.string(url.absoluteString)]) == FetchRequest(url: url))
        #expect(try FetchRequest.parse([.string(url.absoluteString), .null]) == FetchRequest(url: url))
    }

    @Test func `fetch takes A method headers and body`() throws {
        let request = try FetchRequest.parse([
            .string(url.absoluteString),
            .object(["method": "post", "headers": .object(["Authorization": "Bearer token"]), "body": "{}"]),
        ])
        #expect(request == FetchRequest(url: url, method: "POST", headers: ["Authorization": "Bearer token"], body: "{}"))
    }

    @Test func `rejects A non HTTP URL and malformed options`() {
        #expect(throws: ArgumentError("fetch takes an http or https URL")) { try FetchRequest.parse([.string("file:///etc/hosts")]) }
        #expect(throws: ArgumentError("fetch: options must be an object")) { try FetchRequest.parse([.string(url.absoluteString), "GET"]) }
        #expect(throws: ArgumentError("fetch: headers must be an object of strings")) {
            try FetchRequest.parse([.string(url.absoluteString), .object(["headers": .object(["X-Count": 1])])])
        }
        #expect(throws: ArgumentError("fetch: unknown option \"timeout\"; use method, headers, body")) {
            try FetchRequest.parse([.string(url.absoluteString), .object(["timeout": 5])])
        }
    }
}
