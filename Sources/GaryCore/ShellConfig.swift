import Foundation

public enum BarSection: String, CaseIterable, Sendable {
    case left, center, right
}

public struct ShellConfigError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String {
        "shell.json \(path): \(reason)"
    }
}

public struct ShellConfig: Equatable, Sendable {
    public var bar: [BarSection: [PluginID]]
    public var plugins: [PluginID]
    public var disabledPlugins: Set<PluginID>
    public var settings: [PluginID: JSON]
    public var revealMenuBar: Bool
    public var packages: [PackageSource]

    public static let defaults = ShellConfig(
        bar: [.left: [], .center: [], .right: [PluginID(builtin: "battery"), PluginID(builtin: "clock")]],
        plugins: [], disabledPlugins: [], settings: [:], revealMenuBar: true, packages: [],
    )

    private static let revealMenuBarKey = "revealMenuBar"

    public static func parse(_ json: JSON) throws -> ShellConfig {
        guard let fields = json.object else { throw ShellConfigError(path: "root", reason: "must be an object") }
        var config = defaults
        if let bar = fields["bar"] {
            try config.parseBar(bar)
        }
        if let plugins = fields["plugins"] {
            config.plugins = try ids(plugins, "plugins")
        }
        if let disabled = fields["disabledPlugins"] {
            config.disabledPlugins = try Set(ids(disabled, "disabledPlugins"))
        }
        if let settings = fields["settings"] {
            config.settings = try parseSettings(settings)
        }
        if let packages = fields["packages"] {
            config.packages = try parsePackages(packages)
        }
        return config
    }

    private static func parsePackages(_ value: JSON) throws -> [PackageSource] {
        guard let entries = value.array else { throw ShellConfigError(path: "packages", reason: "must be an array of package sources") }
        var identities = Set<PackageIdentity>()
        return try entries.enumerated().map { index, entry in
            let path = "packages[\(index)]"
            guard let raw = entry.string ?? entry["source"]?.string else {
                throw ShellConfigError(path: path, reason: "must be a source string or an object with a source")
            }
            let source: PackageSource
            do {
                source = try PackageSource.parse(raw, base: nil)
            } catch {
                throw ShellConfigError(path: path, reason: "\(error)")
            }
            guard identities.insert(source.identity).inserted else {
                throw ShellConfigError(path: path, reason: "declares \(source.identity) twice")
            }
            return source
        }
    }

    private mutating func parseBar(_ bar: JSON) throws {
        let key = Self.revealMenuBarKey
        guard let sections = bar.object else { throw ShellConfigError(path: "bar", reason: "must be an object") }
        if let unknown = sections.keys.sorted().first(where: { BarSection(rawValue: $0) == nil && $0 != key }) {
            throw ShellConfigError(path: "bar.\(unknown)", reason: "is not left, center, right or \(key)")
        }
        if let reveal = sections[key] {
            guard let value = reveal.bool else { throw ShellConfigError(path: "bar.\(key)", reason: "must be true or false") }
            revealMenuBar = value
        }
        if BarSection.allCases.contains(where: { sections[$0.rawValue] != nil }) {
            self.bar = try Dictionary(uniqueKeysWithValues: BarSection.allCases.map { section in
                try (section, sections[section.rawValue].map { try Self.ids($0, "bar.\(section.rawValue)") } ?? [])
            })
        }
    }

    private static func ids(_ value: JSON, _ path: String) throws -> [PluginID] {
        guard let items = value.array else { throw ShellConfigError(path: path, reason: "must be an array of plugin ids") }
        return try items.enumerated().map { index, item in
            guard let raw = item.string, let id = PluginID(raw) else {
                throw ShellConfigError(path: "\(path)[\(index)]", reason: "is not a plugin id")
            }
            return id
        }
    }

    private static func parseSettings(_ settings: JSON) throws -> [PluginID: JSON] {
        guard let entries = settings.object else {
            throw ShellConfigError(path: "settings", reason: "must be an object keyed by plugin id")
        }
        return try Dictionary(uniqueKeysWithValues: entries.map { key, value in
            guard let id = PluginID(key) else { throw ShellConfigError(path: "settings.\(key)", reason: "is not a plugin id") }
            return (id, value)
        })
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
        let enabledManifests = catalog.plugins.values.filter { bundle in
            let id = bundle.manifest.id
            return !disabledPlugins.contains(id) && (bundle.origin == .builtin || named.contains(id))
        }.map(\.manifest).sorted { $0.id < $1.id }
        let enabled = Set(enabledManifests.map(\.id))

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
        for id in plugins where catalog.plugins[id] == nil {
            warnings.append("plugins: no plugin \(id)")
        }
        for manifest in enabledManifests {
            for case let .plugin(source) in manifest.subscribes where !enabled.contains(source) {
                let state = catalog.plugins[source] == nil ? "not installed" : "not enabled"
                warnings.append("\(manifest.id) subscribes to \(source), which is \(state)")
            }
        }
        let bars = enabledManifests.filter { $0.kinds.contains(.bar) }.map(\.id)
        for id in bars.dropFirst() {
            warnings.append("\(id) is a bar too; \(bars[0]) replaces the built-in bar")
        }
        return Resolution(enabled: enabled, bar: resolved, barPlugin: bars.first, warnings: warnings)
    }
}

public extension ShellConfig {
    enum Change: Equatable, Sendable {
        case enable(PluginID, bar: BarSection?)
        case install(PluginID, bar: BarSection?)
        case disable(PluginID)
        case remove(PluginID)
        case declare(PackageSource)
        case undeclare(PackageIdentity)
    }

    private static func packages(_ change: Change, _ sources: [PackageSource], _ entries: [JSON]) -> [JSON] {
        switch change {
        case let .declare(source):
            var entries = entries
            if let index = sources.firstIndex(where: { $0.identity == source.identity }) {
                entries[index] = .string(source.declaration)
            } else {
                entries.append(.string(source.declaration))
            }
            return entries
        case let .undeclare(identity):
            return zip(entries, sources).filter { $0.1.identity != identity }.map(\.0)
        default:
            return entries
        }
    }

    static func applying(_ change: Change, to json: JSON) throws -> JSON {
        let config = try parse(json)
        var fields = json.object ?? [:]
        var bar = config.bar
        var plugins = config.plugins
        var disabled = config.disabledPlugins
        func enable(_ id: PluginID, _ section: BarSection?) {
            disabled.remove(id)
            if let section {
                if !bar.values.contains(where: { $0.contains(id) }) {
                    bar[section, default: []].append(id)
                }
            } else if !plugins.contains(id) {
                plugins.append(id)
            }
        }
        switch change {
        case let .enable(id, section):
            enable(id, section)
        case let .install(id, section):
            if !bar.values.contains(where: { $0.contains(id) }), !plugins.contains(id), !disabled.contains(id) {
                enable(id, section)
            }
        case let .disable(id):
            disabled.insert(id)
        case let .remove(id):
            bar = bar.mapValues { $0.filter { $0 != id } }
            plugins.removeAll { $0 == id }
            disabled.remove(id)
        case .declare, .undeclare:
            let entries = packages(change, config.packages, fields["packages"]?.array ?? [])
            fields["packages"] = entries.isEmpty ? nil : .array(entries)
            return .object(fields)
        }
        func ids(_ list: [PluginID]) -> JSON {
            .array(list.map { .string($0.rawValue) })
        }
        func set(_ key: String, _ value: JSON, changed: Bool) {
            if changed {
                fields[key] = value
            }
        }
        var barFields = fields["bar"]?.object ?? [:]
        for section in BarSection.allCases {
            barFields[section.rawValue] = ids(bar[section] ?? [])
        }
        set("bar", .object(barFields), changed: bar != config.bar)
        set("plugins", ids(plugins), changed: plugins != config.plugins)
        set("disabledPlugins", ids(disabled.sorted()), changed: disabled != config.disabledPlugins)
        return .object(fields)
    }
}
