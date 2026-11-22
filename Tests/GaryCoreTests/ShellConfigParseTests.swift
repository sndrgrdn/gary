import Foundation
@testable import GaryCore
import Testing

struct ShellConfigParseTests {
    @Test func `each section reports its own path`() throws {
        let cases: [(String, ShellConfigError)] = [
            (#"{"settings": []}"#, ShellConfigError(path: "settings", reason: "must be an object keyed by plugin id")),
            (#"{"plugins": ["acme.a", 3]}"#, ShellConfigError(path: "plugins[1]", reason: "is not a plugin id")),
            (#"{"bar": {"right": "gary.clock"}}"#, ShellConfigError(path: "bar.right", reason: "must be an array of plugin ids")),
        ]
        for (text, warning) in cases {
            #expect(try ShellConfig.parse(JSON.parse(text)).warnings == [warning], "\(text)")
        }
    }

    @Test func `a bar with sections and reveal sets both and fills missing sections`() throws {
        let parsed = try ShellConfig.parse(JSON.parse(#"{"bar": {"center": ["acme.a"], "revealMenuBar": false}, "disabledPlugins": ["acme.b"]}"#))
        let id = try #require(PluginID("acme.a"))
        #expect(parsed.bar == [.left: [], .center: [id], .right: [], .notchLeft: []])
        #expect(!parsed.revealMenuBar)
        #expect(parsed.disabledPlugins == Set(["acme.b"].compactMap(PluginID.init)))
    }

    @Test func `packages are source strings and each package is declared once`() throws {
        let parsed = try ShellConfig.parse(JSON.parse(#"{"packages": ["npm:gary-weather@1.0.0", "git:github.com/you/plugins", "~/dev/plugins"]}"#))
        #expect(parsed.packages.map(\.declaration) == ["npm:gary-weather@1.0.0", "git:github.com/you/plugins", NSHomeDirectory() + "/dev/plugins"])
        let cases: [(String, String)] = [
            (#"{"packages": "npm:a"}"#, "packages"),
            (#"{"packages": [3]}"#, "packages[0]"),
            (#"{"packages": [{"source": "npm:a"}]}"#, "packages[0]"),
            (#"{"packages": ["npm:a@^1.0.0"]}"#, "packages[0]"),
            (#"{"packages": ["./relative"]}"#, "packages[0]"),
            (#"{"packages": ["npm:a", "npm:a@1.0.0"]}"#, "packages[1]"),
        ]
        for (text, path) in cases {
            #expect(try ShellConfig.parse(JSON.parse(text)).warnings.map(\.path) == [path], "\(text)")
        }
        let skipped = try ShellConfig.parse(JSON.parse(#"{"packages": ["npm:a", 3, "npm:b"]}"#))
        #expect(skipped.packages.map(\.declaration) == ["npm:a", "npm:b"])
    }

    @Test func `declaring A package replaces the entry with its identity and undeclaring removes it`() throws {
        let text = #"{"packages": ["npm:gary-weather", "git:github.com/you/plugins"], "bar": {"left": []}}"#
        let replaced = try ShellConfig.applying(.declare(PackageSource.parse("npm:gary-weather@2.0.0", base: nil)), to: JSON.parse(text))
        #expect(replaced["packages"] == .array([.string("npm:gary-weather@2.0.0"), .string("git:github.com/you/plugins")]))
        let added = try ShellConfig.applying(.declare(PackageSource.parse("npm:other", base: nil)), to: replaced)
        #expect(added["packages"]?.array?.count == 3)
        let removed = try ShellConfig.applying(.undeclare(PackageSource.parse("https://github.com/you/plugins", base: nil).identity), to: added)
        #expect(try ShellConfig.parse(removed).packages.map(\.declaration) == ["npm:gary-weather@2.0.0", "npm:other"])
        #expect(try removed["bar"] == JSON.parse(text)["bar"])
        let emptied = try ["npm:gary-weather", "npm:other"].reduce(removed) { try ShellConfig.applying(
            .undeclare(PackageSource.parse($1, base: nil).identity),
            to: $0,
        ) }
        #expect(emptied["packages"] == nil)
    }
}
