import Foundation

enum Paths {
    static let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gary")
    static let userPlugins = config.appending(path: "plugins")
    static let shellConfig = config.appending(path: "shell.json")
    static let userTheme = config.appending(path: "theme.json")
    static let palette = config.appending(path: "palette.toml")
    private static let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    static let builtinPlugins = resources.appending(path: "plugins")
    static let examples = resources.appending(path: "examples")
    static let defaultTheme = resources.appending(path: "theme.json")
    static let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Gary/storage")
    static let systemRestore = storage.deletingLastPathComponent().appending(path: "restore.json")
    static let onboarding = storage.deletingLastPathComponent().appending(path: "onboarding.json")
    static let reopen = storage.deletingLastPathComponent().appending(path: "reopen.json")
}
