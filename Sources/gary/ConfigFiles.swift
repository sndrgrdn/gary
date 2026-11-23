import Foundation
import GaryCore

struct ConfigFiles {
    var shellConfig = Paths.shellConfig
    var palette = Paths.palette
    var userTheme = Paths.userTheme
    var defaultTheme = Paths.defaultTheme
    var builtinPlugins = Paths.builtinPlugins
    var userPlugins = Paths.userPlugins

    func config() throws -> ShellConfig? {
        guard FileManager.default.fileExists(atPath: shellConfig.path) else { return nil }
        return try ShellConfig.parse(JSON.parse(Data(contentsOf: shellConfig)))
    }

    func catalog(_ packages: [PackageSource]) -> PluginCatalog {
        PluginCatalog.scan(
            builtin: builtinPlugins, user: userPlugins, packages: packages.map(PackageStore.directory), capabilities: Capability.names(),
        )
    }

    func paletteFile() throws -> PaletteFile? {
        guard FileManager.default.fileExists(atPath: palette.path) else { return nil }
        return try PaletteFile.parse(String(contentsOf: palette, encoding: .utf8))
    }

    func theme(palette file: PaletteFile?, system: Palette.Mode, override: JSON? = nil) throws -> Theme {
        var override = override
        if FileManager.default.fileExists(atPath: userTheme.path) {
            override = try (override ?? .object([:])).merging(JSON.parse(Data(contentsOf: userTheme)))
        }
        return try Theme.parse(JSON.parse(Data(contentsOf: defaultTheme)), palette: Palette(file, system: system), override: override)
    }
}
