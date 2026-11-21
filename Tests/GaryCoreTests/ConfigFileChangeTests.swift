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

    @Test func `a file inside a plugin root reloads the plugin that holds it`() {
        #expect(change("/home/.config/gary/plugins/weather/widget.js") == .plugin(
            path: "/home/.config/gary/plugins/weather/widget.js",
            rescansCatalog: false,
        ))
        #expect(change("/packages/git/host/o/r/weather/lib/util.js") == .plugin(
            path: "/packages/git/host/o/r/weather/lib/util.js",
            rescansCatalog: false,
        ))
    }

    @Test func `a manifest a root or a folder directly inside it rescans the catalog`() {
        #expect(change("/home/.config/gary/plugins/weather/manifest.json") == .plugin(
            path: "/home/.config/gary/plugins/weather/manifest.json",
            rescansCatalog: true,
        ))
        #expect(change("/home/.config/gary/plugins/weather") == .plugin(path: "/home/.config/gary/plugins/weather", rescansCatalog: true))
        #expect(change("/packages") == .plugin(path: "/packages", rescansCatalog: true))
    }

    @Test func `hidden files and folders are ignored`() {
        #expect(change("/home/.config/gary/plugins/weather/.DS_Store") == nil)
        #expect(change("/packages/git/host/o/r/.git/index") == nil)
        #expect(change("/packages/.staging/abc/manifest.json") == nil)
    }
}
