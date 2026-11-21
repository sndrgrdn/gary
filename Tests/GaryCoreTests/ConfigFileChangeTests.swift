@testable import GaryCore
import Testing

struct ConfigFileChangeTests {
    private func change(_ path: String) -> ConfigFileChange? {
        ConfigFileChange(path: path, configRoot: "/home/.config/gary", pluginsRoot: "/home/.config/gary/plugins")
    }

    @Test func `the theme palette and shell config files are named by their change`() {
        #expect(change("/home/.config/gary/theme.json") == .theme)
        #expect(change("/home/.config/gary/palette.toml") == .palette)
        #expect(change("/home/.config/gary/shell.json") == .shellConfig)
    }

    @Test func `other files outside the plugins folder are not a change`() {
        #expect(change("/home/.config/gary/notes.txt") == nil)
        #expect(change("/home/.config/gary/sub/theme.json") == nil)
        #expect(change("/elsewhere/theme.json") == nil)
    }

    @Test func `a file inside a plugin reloads that plugin`() {
        #expect(change("/home/.config/gary/plugins/weather/widget.js") == .plugin(directory: "weather", rescansCatalog: false))
        #expect(change("/home/.config/gary/plugins/weather/lib/util.js") == .plugin(directory: "weather", rescansCatalog: false))
    }

    @Test func `a manifest or a plugin folder itself rescans the catalog`() {
        #expect(change("/home/.config/gary/plugins/weather/manifest.json") == .plugin(directory: "weather", rescansCatalog: true))
        #expect(change("/home/.config/gary/plugins/weather") == .plugin(directory: "weather", rescansCatalog: true))
    }

    @Test func `hidden files inside a plugin are ignored but a hidden plugin folder is not`() {
        #expect(change("/home/.config/gary/plugins/weather/.DS_Store") == nil)
        #expect(change("/home/.config/gary/plugins/weather/.git/index") == nil)
        #expect(change("/home/.config/gary/plugins/.hidden") == .plugin(directory: ".hidden", rescansCatalog: true))
    }

    @Test func `the plugins folder is matched where it resolves to even outside the config folder`() {
        let change = ConfigFileChange(path: "/dotfiles/plugins/weather/widget.js", configRoot: "/home/.config/gary", pluginsRoot: "/dotfiles/plugins")
        #expect(change == .plugin(directory: "weather", rescansCatalog: false))
    }
}
