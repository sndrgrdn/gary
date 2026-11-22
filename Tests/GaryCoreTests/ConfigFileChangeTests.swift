@testable import GaryCore
import Testing

struct ConfigFileChangeTests {
    private func change(_ path: String) -> ConfigFileChange? {
        ConfigFileChange(path: path, configRoot: "/home/.config/gary", pluginRoots: ["/home/.config/gary/plugins", "/packages"])
    }

    @Test func `the theme palette and shell config files are named by their change`() {
        #expect(change("/home/.config/gary/theme.json") == .theme)
        #expect(change("/home/.config/gary/palette.toml") == .palette)
        #expect(change("/home/.config/gary/shell.json") == .shellConfig)
    }

    @Test func `other files outside the plugin roots are not a change`() {
        #expect(change("/home/.config/gary/notes.txt") == nil)
        #expect(change("/home/.config/gary/sub/theme.json") == nil)
        #expect(change("/elsewhere/theme.json") == nil)
        #expect(change("/packages-old/a/widget.js") == nil)
    }

    private func plugin(_ path: String, rescans: Bool = false) -> ConfigFileChange {
        .plugin(path: path, rescansCatalog: rescans)
    }

    @Test func `a source file inside a plugin root is a plugin change`() {
        for path in [
            "/home/.config/gary/plugins/weather/widget.js",
            "/packages/git/host/o/r/weather/lib/util.js",
            "/packages/npm/weather/widget.tsx",
            "/packages/npm/weather/topic.ts",
            "/packages/npm/weather/glow.metal",
        ] {
            #expect(change(path) == plugin(path))
        }
    }

    @Test func `assets, generated declarations and node modules are not a plugin change`() {
        for path in [
            "/packages/npm/weather/screenshot.png",
            "/packages/npm/weather/README.md",
            "/packages/npm/weather/tsconfig.json",
            "/packages/npm/weather/manifest.schema.json",
            "/packages/npm/weather/gary.d.ts",
            "/packages/npm/weather/node_modules/effect/dist/index.js",
        ] {
            #expect(change(path) == nil, "\(path)")
        }
    }

    @Test func `a root or a folder inside it is a plugin change`() {
        #expect(change("/home/.config/gary/plugins/weather") == plugin("/home/.config/gary/plugins/weather"))
        #expect(change("/packages") == plugin("/packages"))
    }

    @Test func `a manifest rescans the catalog`() {
        let path = "/packages/npm/weather/manifest.json"
        #expect(change(path) == plugin(path, rescans: true))
    }

    @Test func `hidden files and folders are ignored`() {
        #expect(change("/home/.config/gary/plugins/weather/.DS_Store") == nil)
        #expect(change("/packages/git/host/o/r/.git/index") == nil)
        #expect(change("/packages/.staging/abc/manifest.json") == nil)
    }
}
