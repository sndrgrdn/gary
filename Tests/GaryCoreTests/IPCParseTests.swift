import Foundation
@testable import GaryCore
import Testing

struct IPCParseTests {
    private struct Invocation {
        let verb: String
        let arguments: [String]

        init(_ verb: String, _ arguments: [String] = []) {
            self.verb = verb
            self.arguments = arguments
        }

        func parse() throws -> Request {
            try Request.parse(verb: verb, arguments: arguments)
        }
    }

    @Test func `each verb parses to its request`() throws {
        let today = try #require(PluginID("gary.today"))
        let osd = try #require(SurfaceAddress(today, surface: "osd"))
        let cases: [(Invocation, Request)] = [
            (Invocation("ping"), .ping), (Invocation("quit"), .quit), (Invocation("rescanPlugins"), .rescanPlugins),
            (Invocation("reloadConfig"), .reloadConfig), (Invocation("listPlugins"), .listPlugins), (Invocation("doctor"), .doctor),
            (Invocation("onboarding"), .summon(SurfaceAddress(.onboarding))), (Invocation("summon", ["gary.today"]), .summon(SurfaceAddress(today))),
            (Invocation("hide", ["gary.today"]), .hide(SurfaceAddress(today))), (Invocation("reloadPlugins"), .reloadPlugins(nil)),
            (Invocation("toggle", ["gary.today:osd"]), .toggle(osd)),
            (Invocation("reloadPlugins", ["gary.today"]), .reloadPlugins(today)), (Invocation("applyTheme"), .applyTheme(nil)),
            (Invocation("permissions"), .permissions),
            (Invocation("call", ["gary.today", "go", "1", "2"]), .call(today, method: "go", arguments: ["1", "2"])),
            (Invocation("action", ["gary.today/panel", "set"]), .action(today, kind: .panel, action: "set", payload: nil)),
            (Invocation("action", ["gary.today/panel", "set", "0.5"]), .action(today, kind: .panel, action: "set", payload: "0.5")),
            (Invocation("key", ["gary.today", "a", "enter"]), .key(today, kind: nil, keys: ["a", "enter"])),
            (Invocation("key", ["gary.today/menu", "cmd+k"]), .key(today, kind: .menu, keys: ["cmd+k"])),
            (Invocation("scroll", ["gary.today/panel", "-3"]), .scroll(today, kind: .panel, over: nil, by: .lines(-3))),
            (
                Invocation("scroll", ["gary.today/bar-widget", "volume", "12.5", "--precise"]),
                .scroll(today, kind: .barWidget, over: "volume", by: .points(12.5)),
            ),
        ]
        for (invocation, request) in cases {
            #expect(try invocation.parse() == request, "\(invocation.verb) \(invocation.arguments)")
        }
    }

    @Test func `argument counts are checked per verb`() {
        let cases: [(Invocation, String)] = [
            (Invocation("onboarding", ["x"]), "onboarding takes 0 arguments"),
            (Invocation("hide", ["gary.a", "gary.b"]), "hide takes 1 argument"),
            (Invocation("applyTheme", ["{}", "{}"]), "applyTheme takes at most 1 argument"),
            (Invocation("call", ["Today", "go"]), "invalid plugin id \"Today\""),
            (Invocation("summon", ["Today:osd"]), "invalid plugin id \"Today\""),
            (
                Invocation("summon", ["gary.today:"]),
                "invalid surface name in \"gary.today:\"; use lowercase letters, digits and hyphens after the colon",
            ),
            (
                Invocation("hide", ["gary.today:OSD"]),
                "invalid surface name in \"gary.today:OSD\"; use lowercase letters, digits and hyphens after the colon",
            ),
            (Invocation("action", ["gary.today/panel", "set", "1", "2"]), "action takes <plugin>/<kind>, an action and an optional payload"),
            (Invocation("action", ["gary.today", "set"]), "action takes <plugin>/<kind>, such as gary.today/panel"),
            (Invocation("key", ["gary.today"]), "key takes <plugin>[/<kind>] and one or more keys"),
            (
                Invocation("scroll", ["gary.today/panel", "volume"]),
                "scroll takes <plugin>/<kind>, an optional action, a number of lines or points, and an optional --precise",
            ),
            (
                Invocation("scroll", ["gary.today/panel", "a", "b", "3"]),
                "scroll takes <plugin>/<kind>, an optional action, a number of lines or points, and an optional --precise",
            ),
            (
                Invocation("scroll", ["gary.today/panel", "nan"]),
                "scroll takes <plugin>/<kind>, an optional action, a number of lines or points, and an optional --precise",
            ),
            (Invocation("scroll", ["gary.today", "3"]), "scroll takes <plugin>/<kind>, such as gary.today/panel"),
            (Invocation("key", ["gary.today/widget", "a"]), "unknown kind \"widget\"; use bar-widget, bar, panel, overlay, menu, service"),
        ]
        for (invocation, message) in cases {
            #expect(throws: RequestError(description: message)) { try invocation.parse() }
        }
    }
}
