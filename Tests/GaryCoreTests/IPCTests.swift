import Foundation
@testable import GaryCore
import Testing

struct IPCTests {
    private let today: PluginID

    init() throws {
        today = try #require(PluginID("gary.today"))
    }

    private struct BadArguments {
        let verb: String
        let arguments: [String]
        let message: String

        init(_ verb: String, _ arguments: [String], _ message: String) {
            self.verb = verb
            self.arguments = arguments
            self.message = message
        }
    }

    @Test func `every request survives the wire`() throws {
        let requests: [Request] = [
            .ping, .quit, .summon(today), .hide(today), .toggle(today), .reloadPlugins(nil), .reloadPlugins(today),
            .rescanPlugins, .reloadConfig, .applyTheme(nil), .applyTheme(.object(["colors": .object(["accent": .string("#ff0000")])])),
            .listPlugins, .call(today, method: "refresh", arguments: ["a b", "line\nbreak"]),
            .doctor, .permissions, .requestPermission(.fullDiskAccess),
            .action(today, kind: .barWidget, action: "toggle", payload: nil), .action(today, kind: .panel, action: "volume", payload: "0.5"),
        ]
        for request in requests {
            #expect(!request.line.contains("\n"))
            #expect(try Request.decode(line: request.line) == request)
            #expect(try Request.parse(verb: request.verb, arguments: request.arguments) == request)
        }
    }

    @Test func `the wire format is A verb and string args`() throws {
        #expect(Request.toggle(today).line == #"{"args":["gary.today"],"verb":"toggle"}"#)
        #expect(try Request.decode(line: #"{"verb":"ping"}"#) == .ping)
        #expect(try Request.parse(verb: "onboarding", arguments: []) == .summon(.onboarding))
    }

    @Test func `cli arguments parse like the wire`() throws {
        #expect(try Request.parse(verb: "toggle", arguments: ["gary.today"]) == .toggle(today))
        #expect(try Request.parse(verb: "call", arguments: ["gary.today", "refresh"]) == .call(today, method: "refresh", arguments: []))
        #expect(try Request
            .parse(verb: "applyTheme", arguments: [#"{"bar":{"height":28}}"#]) == .applyTheme(.object(["bar": .object(["height": .number(28)])])))
        #expect(try Request.parse(verb: "permissions", arguments: ["request", "screen-recording"]) == .requestPermission(.screenRecording))
    }

    @Test func `rejects bad arguments`() {
        let cases: [BadArguments] = [
            BadArguments("ping", ["x"], "ping takes 0 arguments"),
            BadArguments("toggle", [], "toggle takes 1 argument"),
            BadArguments("toggle", ["Today"], "invalid plugin id \"Today\""),
            BadArguments("reloadPlugins", ["gary.a", "gary.b"], "reloadPlugins takes at most 1 argument"),
            BadArguments("applyTheme", ["[1]"], "applyTheme takes a JSON object"),
            BadArguments("call", ["gary.today"], "call takes a plugin, a method and optional arguments"),
            BadArguments("permissions", ["accessibility"], "permissions takes no arguments, or request and a permission name"),
            BadArguments(
                "permissions",
                ["request", "camera"],
                "unknown permission \"camera\"; use accessibility, bluetooth, full-disk-access, location, screen-recording",
            ),
            BadArguments("action", ["gary.today", "widget", "toggle"], "unknown kind \"widget\"; use bar-widget, bar, panel, overlay, menu, service"),
            BadArguments("action", ["gary.today", "panel"], "action takes a plugin, a kind, an action and an optional payload"),
            BadArguments("reboot", [], "unknown verb \"reboot\""),
        ]
        for badCase in cases {
            #expect(throws: RequestError(description: badCase.message)) { try Request.parse(verb: badCase.verb, arguments: badCase.arguments) }
        }
    }

    @Test func `rejects malformed lines`() {
        for line in ["ping", "{}", #"{"verb": 1}"#, #"{"verb":"toggle","args":[1]}"#] {
            #expect(throws: RequestError.self, "\(line)") { try Request.decode(line: line) }
        }
    }

    @Test func `responses round trip on one line`() throws {
        for response in [Response.ok("pong"), .ok("a\tb\nc"), .failure("no plugin \"x\"")] {
            #expect(!response.line.contains("\n"))
            #expect(try Response.decode(line: response.line) == response)
        }
        #expect(Response.ok("pong").line == #"{"ok":true,"result":"pong"}"#)
        #expect(throws: RequestError.self) { try Response.decode(line: #"{"ok":true}"#) }
    }
}
