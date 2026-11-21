public enum ConfigFileChange: Equatable, Sendable {
    case theme
    case palette
    case shellConfig
    case plugin(path: String, rescansCatalog: Bool)

    public init?(path: String, configRoot: String, pluginRoots: [String]) {
        if path == configRoot + "/theme.json" {
            self = .theme
        } else if path == configRoot + "/palette.toml" {
            self = .palette
        } else if path == configRoot + "/shell.json" {
            self = .shellConfig
        } else if let root = pluginRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            let components = path.dropFirst(root.count).split(separator: "/")
            guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
            self = .plugin(path: path, rescansCatalog: components.count <= 1 || components.last == "manifest.json")
        } else {
            return nil
        }
    }
}
