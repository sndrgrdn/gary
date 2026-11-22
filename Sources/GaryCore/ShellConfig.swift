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
    public var warnings: [ShellConfigError] = []

    public static let defaults = ShellConfig(
        bar: [.left: [], .center: [], .right: [PluginID(builtin: "battery"), PluginID(builtin: "clock")]],
        plugins: [], disabledPlugins: [], settings: [:], revealMenuBar: true, packages: [],
    )

    private static let revealMenuBarKey = "revealMenuBar"

    public static func parse(_ json: JSON) throws -> ShellConfig {
        guard let fields = json.object else { throw ShellConfigError(path: "root", reason: "must be an object") }
        var config = defaults
        if let bar = fields["bar"] {
            config.parseBar(bar)
        }
        if let plugins = fields["plugins"] {
            config.plugins = config.ids(plugins, "plugins")
        }
        if let disabled = fields["disabledPlugins"] {
            config.disabledPlugins = Set(config.ids(disabled, "disabledPlugins"))
        }
        if let settings = fields["settings"] {
            config.parseSettings(settings)
        }
        if let packages = fields["packages"] {
            config.parsePackages(packages)
        }
        return config
    }

    private mutating func warn(_ path: String, _ reason: String) {
        warnings.append(ShellConfigError(path: path, reason: reason))
    }

    private mutating func parsePackages(_ value: JSON) {
        guard let entries = value.array else { warn("packages", "must be an array of package sources")
            return
        }
        var identities = Set<PackageIdentity>()
        for (index, entry) in entries.enumerated() {
            let path = "packages[\(index)]"
            guard let raw = entry.string else {
                warn(path, "must be a source string")
                continue
            }
            do {
                let source = try PackageSource.parse(raw, base: nil)
                if identities.insert(source.identity).inserted {
                    packages.append(source)
                } else {
                    warn(path, "declares \(source.identity) twice")
                }
            } catch {
                warn(path, "\(error)")
            }
        }
    }

    private mutating func parseBar(_ bar: JSON) {
        let key = Self.revealMenuBarKey
        guard let sections = bar.object else { warn("bar", "must be an object")
            return
        }
        for unknown in sections.keys.sorted() where BarSection(rawValue: unknown) == nil && unknown != key {
            warn("bar.\(unknown)", "is not left, center, right or \(key)")
        }
        if let reveal = sections[key] {
            if let value = reveal.bool {
                revealMenuBar = value
            } else {
                warn("bar.\(key)", "must be true or false")
            }
        }
        if BarSection.allCases.contains(where: { sections[$0.rawValue] != nil }) {
            for section in BarSection.allCases {
                let ids = sections[section.rawValue].map { ids($0, "bar.\(section.rawValue)") } ?? []
                self.bar[section] = ids
            }
        }
    }

    private mutating func ids(_ value: JSON, _ path: String) -> [PluginID] {
        guard let items = value.array else {
            warn(path, "must be an array of plugin ids")
            return []
        }
        return items.enumerated().compactMap { index, item in
            guard let raw = item.string, let id = PluginID(raw) else {
                warn("\(path)[\(index)]", "is not a plugin id")
                return nil
            }
            return id
        }
    }

    private mutating func parseSettings(_ value: JSON) {
        guard let entries = value.object else { warn("settings", "must be an object keyed by plugin id")
            return
        }
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            if let id = PluginID(key) {
                settings[id] = value
            } else {
                warn("settings.\(key)", "is not a plugin id")
            }
        }
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
            for case let .plugin(source) in manifest.topics where !enabled.contains(source) {
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
        guard config.warnings.isEmpty else { throw config.warnings[0] }
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
