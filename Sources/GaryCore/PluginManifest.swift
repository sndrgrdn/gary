import Foundation

public enum PluginKind: String, CaseIterable, Sendable {
    case barWidget = "bar-widget"
    case bar, panel, overlay, menu, service

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
    case builtinOutsideNamespace(PluginID)
    case noKinds
    case unknownKind(String)
    case duplicateKind(PluginKind)
    case missingEntryPoint(PluginKind)
    case entryPointWithoutKind(String)
    case unsafeEntryPoint(String)
    case unknownTopic(String)
    case unknownService(String)
    case invalidHotkey(String)
    case duplicateHotkey(String)

    public var description: String {
        switch self {
        case .invalidJSON: "manifest is not a JSON object"
        case let .missingField(field): "missing field \(field)"
        case let .wrongType(field): "field \(field) has the wrong type"
        case let .unsupportedSchemaVersion(version): "unsupported schemaVersion \(JSON.number(version).text)"
        case let .invalidID(id): "invalid id \"\(id)\""
        case let .reservedID(id): "id \(id) uses the reserved gary. namespace"
        case let .builtinOutsideNamespace(id): "built-in id \(id) is outside the gary. namespace"
        case .noKinds: "kinds is empty"
        case let .unknownKind(kind): "unknown kind \(kind)"
        case let .duplicateKind(kind): "kind \(kind.rawValue) is listed twice"
        case let .missingEntryPoint(kind): "no entry point for kind \(kind.rawValue)"
        case let .entryPointWithoutKind(key): "entry point \(key) has no matching kind"
        case let .unsafeEntryPoint(path): "entry point \(path) must be a relative \(ScriptLanguage.extensions) path inside the plugin"
        case let .unknownTopic(topic): "unknown subscription \(topic)"
        case let .unknownService(service): "unknown host service \(service)"
        case let .invalidHotkey(keys): "hotkey \"\(keys)\" must be modifiers and a key, such as ctrl+alt+space"
        case let .duplicateHotkey(id): "hotkey id \(id) is listed twice"
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
    public let subscribes: [Topic]
    public let uses: [String]
    public let hotkeys: [Hotkey]
    public var bar: BarSection = .right

    public var barPlacement: BarSection? {
        kinds.contains(.barWidget) ? bar : nil
    }

    public var capabilities: [String] {
        var names = uses
        for case let .capability(name) in subscribes where !names.contains(name) {
            names.append(name)
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
        let subscribes = try fields.optionalStrings("subscribes").map { try parseTopic($0, capabilities: capabilities) }
        let uses = try fields.optionalStrings("uses")
        if let unknown = uses.first(where: { !capabilities.uses.contains($0) }) {
            throw ManifestError.unknownService(unknown)
        }
        let hotkeys = try parseHotkeys(fields.optional("hotkeys", \.array, default: []))
        let bar = try fields.optional("bar", { $0.string.flatMap(BarSection.init(rawValue:)) }, default: .right)

        return PluginManifest(
            id: id, name: name, version: version, kinds: kinds, entryPoints: entryPoints,
            keepLoaded: keepLoaded, subscribes: subscribes, uses: uses, hotkeys: hotkeys, bar: bar,
        )
    }

    private static func parseID(_ raw: String, origin: PluginOrigin) throws -> PluginID {
        guard let id = PluginID(raw) else { throw ManifestError.invalidID(raw) }
        switch origin {
        case .user where id.isReserved: throw ManifestError.reservedID(id)
        case .builtin where !id.isReserved: throw ManifestError.builtinOutsideNamespace(id)
        default: return id
        }
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
            guard isSafeRelativeScriptPath(path) else { throw ManifestError.unsafeEntryPoint(path) }
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
}

func isSafeRelativeScriptPath(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.hasPrefix("/") && !path.hasPrefix("~") && ScriptLanguage(path: path) != nil && !path.contains("\0")
        && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
