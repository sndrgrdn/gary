import Foundation

nonisolated enum Paths {
    private static let environment = ProcessInfo.processInfo.environment
    private static let homeOverride = environment["GARY_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    private static let runtimeOverride = environment["GARY_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    static let isolated = homeOverride != nil || runtimeOverride != nil
    static let drivesSystem = !isolated || environment["GARY_ISOLATED_SYSTEM"] == "1"
    static let userHome = FileManager.default.homeDirectoryForCurrentUser
    static let home = homeOverride ?? userHome
    static let runtime = runtimeOverride ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    static let config = home.appending(path: ".config/gary")
    static let userPlugins = config.appending(path: "plugins")
    static let shellConfig = config.appending(path: "shell.json")
    static let userTheme = config.appending(path: "theme.json")
    static let palette = config.appending(path: "palette.toml")
    private static let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    static let builtinPlugins = resources.appending(path: "plugins")
    static let examples = resources.appending(path: "examples")
    static let defaultTheme = resources.appending(path: "theme.json")
    static let sucrase = resources.appending(path: "sucrase.js")
    static let effect = resources.appending(path: "effect.js")
    static let support = home.appending(path: "Library/Application Support/Gary")
    static let storage = support.appending(path: "storage")
    static let packages = support.appending(path: "packages")
    static let systemRestore = support.appending(path: "restore.json")
    static let onboarding = support.appending(path: "onboarding.json")
    static let reopen = support.appending(path: "reopen.json")
    static let caches = home.appending(path: "Library/Caches")
    static let transpiled = caches.appending(path: "Gary/transpiled")
    static let log = home.appending(path: "Library/Logs/gary.log")
    static let appLock = runtime.appending(path: "gary.lock").path
    static let supervisorLock = runtime.appending(path: "gary-supervisor.lock").path
    static let socket = runtime.appending(path: "gary.sock").path
}
