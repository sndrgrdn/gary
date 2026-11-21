public enum ConfigFileChange: Equatable, Sendable {
    case theme
    case palette
    case shellConfig
    case plugin(directory: String, rescansCatalog: Bool)

    public init?(path: String, configRoot: String, pluginsRoot: String) {
        let plugins = pluginsRoot + "/"
        if path == configRoot + "/theme.json" {
            self = .theme
        } else if path == configRoot + "/palette.toml" {
            self = .palette
        } else if path == configRoot + "/shell.json" {
            self = .shellConfig
        } else if path.hasPrefix(plugins) {
            let relative = path.dropFirst(plugins.count)
            guard !relative.split(separator: "/").dropFirst().contains(where: { $0.hasPrefix(".") }) else { return nil }
            self = .plugin(
                directory: String(relative.prefix { $0 != "/" }),
                rescansCatalog: relative.hasSuffix("/manifest.json") || !relative.contains("/"),
            )
        } else {
            return nil
        }
    }
}
