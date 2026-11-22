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
            guard !components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) else { return nil }
            let name = String(components.last ?? "")
            guard name == "manifest.json" || Self.isSource(name) || !name.contains(".") else { return nil }
            self = .plugin(path: path, rescansCatalog: name == "manifest.json")
        } else {
            return nil
        }
    }

    private static func isSource(_ name: String) -> Bool {
        (ScriptLanguage(path: name) != nil && !name.hasSuffix(".d.ts")) || name.hasSuffix(".metal")
    }
}
