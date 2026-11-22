import Foundation

public enum PluginKind: String, CaseIterable, Sendable {
    case barWidget = "bar-widget"
    case bar, panel, overlay, menu, service

    public static let handlerOrder: [PluginKind] = [.service, .panel, .overlay, .menu, .bar, .barWidget]

    public var isSurface: Bool {
        self == .panel || self == .overlay || self == .menu
    }

    public func hides(onUnhandled key: String) -> Bool {
        key == "escape" && (self == .menu || self == .overlay)
    }
}

public enum Topic: Hashable, Sendable, CustomStringConvertible {
    case capability(String)
    case plugin(PluginID)

    public var description: String {
        switch self {
        case let .capability(name): name
        case let .plugin(id): id.rawValue
        }
    }
}

public enum PluginOrigin: Sendable {
    case builtin, user
}

public struct PluginID: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let rawValue: String

    public init?(_ raw: String) {
        let segments = raw.split(separator: ".", omittingEmptySubsequences: false)
        let valid = raw.count <= 128 && segments.count >= 2 && segments.allSatisfy { segment in
            guard let first = segment.first, first.isASCII, first.isLetter || first.isNumber else { return false }
            return segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        }
        guard valid else { return nil }
        rawValue = raw
    }

    init(builtin name: String) {
        rawValue = "gary.\(name)"
    }

    public var isReserved: Bool {
        rawValue.hasPrefix("gary.")
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: PluginID, rhs: PluginID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case invalidJSON
    case missingField(String)
    case wrongType(String)
    case unsupportedSchemaVersion(Double)
    case invalidID(String)
    case reservedID(PluginID)
    case noKinds
    case unknownKind(String)
    case duplicateKind(PluginKind)
    case missingEntryPoint(PluginKind)
    case entryPointWithoutKind(String)
    case entryPointNotScript(String)
    case unknownTopic(String)
    case unknownService(String)
    case invalidHotkey(String)
    case duplicateHotkey(String)
    case kindNotListed(field: String, kind: String)
    case surfacesOutsideSurfaceKind(PluginKind)
    case invalidSurfaceName(String)
    case noSurfaces(PluginKind)
    case duplicateSurface(String)
    case surfacesDiffer(PluginKind, exported: [String], listed: [String])
    case unknownMediaKey(String)

    public var description: String {
        switch self {
        case .invalidJSON: "manifest is not a JSON object"
        case let .missingField(field): "missing field \(field)"
        case let .wrongType(field): "field \(field) has the wrong type"
        case let .unsupportedSchemaVersion(version): "unsupported schemaVersion \(JSON.number(version).text)"
        case let .invalidID(id): "invalid id \"\(id)\""
        case let .reservedID(id): "id \(id) uses the reserved gary. namespace"
        case .noKinds: "kinds is empty"
        case let .unknownKind(kind): "unknown kind \(kind)"
        case let .duplicateKind(kind): "kind \(kind.rawValue) is listed twice"
        case let .missingEntryPoint(kind): "no entry point for kind \(kind.rawValue)"
        case let .entryPointWithoutKind(key): "entry point \(key) has no matching kind"
        case let .entryPointNotScript(path): "entry point \(path) must be a \(ScriptLanguage.extensions) file"
        case let .unknownTopic(topic): "unknown subscription \(topic)"
        case let .unknownService(service): "unknown host service \(service)"
        case let .invalidHotkey(keys): "hotkey \"\(keys)\" must be modifiers and a key, such as ctrl+alt+space"
        case let .duplicateHotkey(id): "hotkey id \(id) is listed twice"
        case let .kindNotListed(field, kind): "\(field).\(kind) names a kind that kinds does not list"
        case let .surfacesOutsideSurfaceKind(kind): "surfaces.\(kind.rawValue): only a panel, overlay, or menu has surfaces"
        case let .invalidSurfaceName(name): "surface name \"\(name)\" must be lowercase letters, digits, and hyphens"
        case let .noSurfaces(kind): "surfaces.\(kind.rawValue) lists no surface"
        case let .duplicateSurface(name): "surface \(name) belongs to two kinds; give each panel, overlay, and menu its own names in surfaces"
        case let .unknownMediaKey(name): MediaKey.UnknownKey(name: name).description
        case let .surfacesDiffer(kind, exported, listed):
            "the module exports surfaces \(exported.joined(separator: ", ")), but manifest.json gives the \(kind.rawValue) "
                + "\(listed.joined(separator: ", ")); list its surface names in surfaces.\(kind.rawValue)"
        }
    }
}

public struct PluginManifest: Equatable, Sendable {
    public static let schemaVersion = 1

    public let id: PluginID
    public let name: String
    public let version: String
    public let kinds: [PluginKind]
    public let entryPoints: [PluginKind: String]
    public let keepLoaded: Bool
    public let subscriptions: [PluginKind: [Topic]]
    public let uses: [String]
    public let hotkeys: [Hotkey]
    public var surfaces: [PluginKind: [String]] = [:]
    public var mediaKeys: [PluginKind: Set<MediaKey>] = [:]
    public var bar: BarSection = .right

    public var surfaceNames: [String] {
        surfaces.values.joined().sorted()
    }

    public func surfaceKind(_ name: String) -> PluginKind? {
        surfaces.first { $0.value.contains(name) }?.key
    }

    public func checkSurfaces(of kind: PluginKind, exported names: some Sequence<String>) throws {
        let exported = names.sorted()
        let listed = (surfaces[kind] ?? []).sorted()
        guard exported == listed else { throw ManifestError.surfacesDiffer(kind, exported: exported, listed: listed) }
    }

    public var barPlacement: BarSection? {
        kinds.contains(.barWidget) ? bar : nil
    }

    public var topics: [Topic] {
        var topics: [Topic] = []
        for topic in kinds.flatMap({ subscriptions[$0] ?? [] }) where !topics.contains(topic) {
            topics.append(topic)
        }
        return topics
    }

    public var capabilities: [String] {
        var names = uses
        for case let .capability(name) in topics where !names.contains(name) {
            names.append(name)
        }
        if !mediaKeys.isEmpty {
            names.append(MediaKey.capability)
        }
        return names
    }

    public static func parse(_ data: Data, origin: PluginOrigin, capabilities: CapabilityNames) throws -> PluginManifest {
        guard let json = try? JSON.parse(data), case .object = json else { throw ManifestError.invalidJSON }
        let fields = ManifestFields(json: json)

        let schema = try fields.required("schemaVersion", \.number)
        guard schema == Double(schemaVersion) else { throw ManifestError.unsupportedSchemaVersion(schema) }

        let id = try parseID(fields.required("id", \.string), origin: origin)
        let name = try fields.required("name", \.string)
        let version = try fields.required("version", \.string)
        let kinds = try parseKinds(fields.strings("kinds"))
        let entryPoints = try parseEntryPoints(fields.required("entryPoints", \.object), kinds: kinds)
        let keepLoaded = try fields.optional("keepLoaded", \.bool, default: false)
        let subscriptions = try fields.subscriptions(kinds: kinds).mapValues { try $0.map { try parseTopic($0, capabilities: capabilities) } }
        let uses = try fields.optionalStrings("uses")
        if let unknown = uses.first(where: { !capabilities.uses.contains($0) }) {
            throw ManifestError.unknownService(unknown)
        }
        let hotkeys = try parseHotkeys(fields.optional("hotkeys", \.array, default: []))
        let bar = try fields.optional("bar", { $0.string.flatMap(BarSection.init(rawValue:)) }, default: .right)
        let surfaces = try parseSurfaces(fields.perKind("surfaces", kinds: kinds), kinds: kinds)
        let mediaKeys = try fields.perKind(MediaKey.capability, kinds: kinds).compactMapValues { names in
            do {
                let keys = try MediaKey.parse(names)
                return keys.isEmpty ? nil : keys
            } catch let error as MediaKey.UnknownKey {
                throw ManifestError.unknownMediaKey(error.name)
            }
        }

        return PluginManifest(
            id: id, name: name, version: version, kinds: kinds, entryPoints: entryPoints,
            keepLoaded: keepLoaded, subscriptions: subscriptions, uses: uses, hotkeys: hotkeys, surfaces: surfaces, mediaKeys: mediaKeys, bar: bar,
        )
    }

    private static func parseSurfaces(_ listed: [PluginKind: [String]], kinds: [PluginKind]) throws -> [PluginKind: [String]] {
        if let kind = listed.keys.first(where: { !$0.isSurface }) {
            throw ManifestError.surfacesOutsideSurfaceKind(kind)
        }
        var owners: [String: PluginKind] = [:]
        var surfaces: [PluginKind: [String]] = [:]
        for kind in kinds where kind.isSurface {
            let names = listed[kind] ?? [SurfaceAddress.main]
            guard !names.isEmpty else { throw ManifestError.noSurfaces(kind) }
            for name in names {
                guard SurfaceAddress.isName(name) else { throw ManifestError.invalidSurfaceName(name) }
                guard owners.updateValue(kind, forKey: name) == nil else { throw ManifestError.duplicateSurface(name) }
            }
            surfaces[kind] = names
        }
        return surfaces
    }

    private static func parseID(_ raw: String, origin: PluginOrigin) throws -> PluginID {
        guard let id = PluginID(raw) else { throw ManifestError.invalidID(raw) }
        guard origin == .builtin || !id.isReserved else { throw ManifestError.reservedID(id) }
        return id
    }

    private static func parseKinds(_ rawKinds: [String]) throws -> [PluginKind] {
        guard !rawKinds.isEmpty else { throw ManifestError.noKinds }
        var kinds: [PluginKind] = []
        for raw in rawKinds {
            guard let kind = PluginKind(rawValue: raw) else { throw ManifestError.unknownKind(raw) }
            guard !kinds.contains(kind) else { throw ManifestError.duplicateKind(kind) }
            kinds.append(kind)
        }
        return kinds
    }

    private static func parseEntryPoints(_ rawEntries: [String: JSON], kinds: [PluginKind]) throws -> [PluginKind: String] {
        var entryPoints: [PluginKind: String] = [:]
        for (key, value) in rawEntries {
            guard let kind = PluginKind(rawValue: key), kinds.contains(kind) else { throw ManifestError.entryPointWithoutKind(key) }
            guard let path = value.string else { throw ManifestError.wrongType("entryPoints.\(key)") }
            guard ScriptLanguage(path: path) != nil else { throw ManifestError.entryPointNotScript(path) }
            entryPoints[kind] = path
        }
        if let missing = kinds.first(where: { entryPoints[$0] == nil }) {
            throw ManifestError.missingEntryPoint(missing)
        }
        return entryPoints
    }

    private static func parseTopic(_ raw: String, capabilities: CapabilityNames) throws -> Topic {
        if capabilities.topics.contains(raw) {
            return .capability(raw)
        }
        guard let id = PluginID(raw) else { throw ManifestError.unknownTopic(raw) }
        return .plugin(id)
    }

    private static func parseHotkeys(_ entries: [JSON]) throws -> [Hotkey] {
        var hotkeys: [Hotkey] = []
        for (index, entry) in entries.enumerated() {
            guard let id = entry["id"]?.string, !id.isEmpty,
                  let raw = entry["keys"]?.string else { throw ManifestError.wrongType("hotkeys[\(index)]") }
            guard let keys = KeyCombo.parse(raw) else { throw ManifestError.invalidHotkey(raw) }
            guard !hotkeys.contains(where: { $0.id == id }) else { throw ManifestError.duplicateHotkey(id) }
            hotkeys.append(Hotkey(id: id, keys: keys))
        }
        return hotkeys
    }
}

private struct ManifestFields {
    let json: JSON

    func required<T>(_ name: String, _ read: (JSON) -> T?) throws -> T {
        guard let value = json[name] else { throw ManifestError.missingField(name) }
        guard let typed = read(value) else { throw ManifestError.wrongType(name) }
        return typed
    }

    func optional<T>(_ name: String, _ read: (JSON) -> T?, default fallback: T) throws -> T {
        json[name] == nil ? fallback : try required(name, read)
    }

    func strings(_ name: String) throws -> [String] {
        try required(name, \.array).map { item in
            guard let string = item.string else { throw ManifestError.wrongType(name) }
            return string
        }
    }

    func optionalStrings(_ name: String) throws -> [String] {
        json[name] == nil ? [] : try strings(name)
    }

    func subscriptions(kinds: [PluginKind]) throws -> [PluginKind: [String]] {
        if json["subscribes"]?.object != nil {
            let lists = try perKind("subscribes", kinds: kinds)
            return Dictionary(uniqueKeysWithValues: kinds.map { ($0, lists[$0] ?? []) })
        }
        let topics = try optionalStrings("subscribes")
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0, topics) })
    }

    func perKind(_ name: String, kinds: [PluginKind]) throws -> [PluginKind: [String]] {
        var lists: [PluginKind: [String]] = [:]
        for (key, value) in try optional(name, \.object, default: [:]) {
            guard let kind = PluginKind(rawValue: key), kinds.contains(kind) else { throw ManifestError.kindNotListed(field: name, kind: key) }
            guard let items = value.array, case let strings = items.compactMap(\.string), strings.count == items.count else {
                throw ManifestError.wrongType("\(name).\(key)")
            }
            lists[kind] = strings
        }
        return lists
    }
}
