import Foundation

public enum BarSection: String, CaseIterable, Sendable {
    case left, center, right
}

public struct ShellConfigError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "shell.json \(path): \(reason)" }
}

public struct ShellConfig: Equatable, Sendable {
    public var bar: [BarSection: [PluginID]]
    public var plugins: [PluginID]
    public var disabledPlugins: Set<PluginID>
    public var settings: [PluginID: JSON]

    public static let defaults = ShellConfig(
        bar: [.left: [], .center: [], .right: [PluginID("gary.battery")!, PluginID("gary.clock")!]],
        plugins: [], disabledPlugins: [], settings: [:]
    )

    public static func parse(_ json: JSON) throws -> ShellConfig {
        func fail(_ path: String, _ reason: String) -> ShellConfigError { ShellConfigError(path: path, reason: reason) }
        guard let fields = json.object else { throw fail("root", "must be an object") }
        func ids(_ value: JSON, _ path: String) throws -> [PluginID] {
            guard let items = value.array else { throw fail(path, "must be an array of plugin ids") }
            return try items.enumerated().map { index, item in
                guard let raw = item.string, let id = PluginID(raw) else { throw fail("\(path)[\(index)]", "is not a plugin id") }
                return id
            }
        }

        var config = defaults
        if let bar = fields["bar"] {
            guard let sections = bar.object else { throw fail("bar", "must be an object") }
            if let unknown = sections.keys.sorted().first(where: { BarSection(rawValue: $0) == nil }) {
                throw fail("bar.\(unknown)", "is not left, center or right")
            }
            config.bar = Dictionary(uniqueKeysWithValues: try BarSection.allCases.map { section in
                (section, try sections[section.rawValue].map { try ids($0, "bar.\(section.rawValue)") } ?? [])
            })
        }
        if let plugins = fields["plugins"] { config.plugins = try ids(plugins, "plugins") }
        if let disabled = fields["disabledPlugins"] { config.disabledPlugins = Set(try ids(disabled, "disabledPlugins")) }
        if let settings = fields["settings"] {
            guard let entries = settings.object else { throw fail("settings", "must be an object keyed by plugin id") }
            config.settings = Dictionary(uniqueKeysWithValues: try entries.map { key, value in
                guard let id = PluginID(key) else { throw fail("settings.\(key)", "is not a plugin id") }
                return (id, value)
            })
        }
        return config
    }

    public struct Resolution: Equatable, Sendable {
        public var enabled: Set<PluginID>
        public var bar: [BarSection: [PluginID]]
        public var barPlugin: PluginID?
        public var warnings: [String]
    }

    public func resolve(_ catalog: PluginCatalog) -> Resolution {
        var warnings: [String] = []
        let named = Set(bar.values.joined()).union(plugins)
        let enabled = Set(catalog.plugins.values.filter { bundle in
            let id = bundle.manifest.id
            return !disabledPlugins.contains(id) && (bundle.origin == .builtin || named.contains(id))
        }.map(\.manifest.id))

        var placed = Set<PluginID>()
        var resolved: [BarSection: [PluginID]] = [:]
        for section in BarSection.allCases {
            resolved[section] = (bar[section] ?? []).filter { id in
                guard let bundle = catalog.plugins[id] else {
                    warnings.append("bar.\(section.rawValue): no plugin \(id)")
                    return false
                }
                guard bundle.manifest.kinds.contains(.barWidget) else {
                    warnings.append("bar.\(section.rawValue): \(id) is not a bar widget")
                    return false
                }
                guard enabled.contains(id) else { return false }
                guard placed.insert(id).inserted else {
                    warnings.append("bar.\(section.rawValue): \(id) is already in the bar")
                    return false
                }
                return true
            }
        }
        for id in plugins where catalog.plugins[id] == nil { warnings.append("plugins: no plugin \(id)") }
        for id in enabled.sorted() {
            for case .plugin(let source) in catalog.plugins[id]!.manifest.subscribes where !enabled.contains(source) {
                warnings.append("\(id) subscribes to \(source), which is \(catalog.plugins[source] == nil ? "not installed" : "not enabled")")
            }
        }
        let bars = enabled.filter { catalog.plugins[$0]!.manifest.kinds.contains(.bar) }.sorted()
        for id in bars.dropFirst() { warnings.append("\(id) is a bar too; \(bars[0]) replaces the built-in bar") }
        return Resolution(enabled: enabled, bar: resolved, barPlugin: bars.first, warnings: warnings)
    }
}

extension ShellConfig {
    public enum Change: Equatable, Sendable {
        case enable(PluginID, inBar: Bool)
        case disable(PluginID)
        case remove(PluginID)
    }

    public static func applying(_ change: Change, to json: JSON) throws -> JSON {
        let config = try parse(json)
        var fields = json.object ?? [:]
        var bar = config.bar, plugins = config.plugins, disabled = config.disabledPlugins
        switch change {
        case .enable(let id, let inBar):
            disabled.remove(id)
            if inBar {
                if !bar.values.contains(where: { $0.contains(id) }) { bar[.right, default: []].insert(id, at: 0) }
            } else if !plugins.contains(id) {
                plugins.append(id)
            }
        case .disable(let id):
            disabled.insert(id)
        case .remove(let id):
            bar = bar.mapValues { $0.filter { $0 != id } }
            plugins.removeAll { $0 == id }
            disabled.remove(id)
        }
        func ids(_ list: [PluginID]) -> JSON { .array(list.map { .string($0.rawValue) }) }
        func set(_ key: String, _ value: JSON, changed: Bool) {
            if changed || fields[key] != nil { fields[key] = value }
        }
        set("bar", .object(Dictionary(uniqueKeysWithValues: BarSection.allCases.map { ($0.rawValue, ids(bar[$0] ?? [])) })), changed: bar != config.bar)
        set("plugins", ids(plugins), changed: plugins != config.plugins)
        set("disabledPlugins", ids(disabled.sorted()), changed: disabled != config.disabledPlugins)
        return .object(fields)
    }
}
