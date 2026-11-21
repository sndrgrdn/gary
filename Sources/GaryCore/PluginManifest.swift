import Foundation

public enum PluginKind: String, CaseIterable, Sendable {
    case barWidget = "bar-widget"
    case bar, panel, overlay, menu, service

    public var isSurface: Bool { self == .panel || self == .overlay || self == .menu }
}

public enum Topic: String, CaseIterable, Sendable {
    case battery, clock
}

public enum HostService: String, CaseIterable, Sendable {
    case exec
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

    public var isReserved: Bool { rawValue.hasPrefix("gary.") }
    public var description: String { rawValue }
    public static func < (a: PluginID, b: PluginID) -> Bool { a.rawValue < b.rawValue }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case invalidJSON
    case missingField(String)
    case wrongType(String)
    case unsupportedSchemaVersion(Int)
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

    public var description: String {
        switch self {
        case .invalidJSON: return "manifest is not a JSON object"
        case .missingField(let field): return "missing field \(field)"
        case .wrongType(let field): return "field \(field) has the wrong type"
        case .unsupportedSchemaVersion(let version): return "unsupported schemaVersion \(version)"
        case .invalidID(let id): return "invalid id \"\(id)\""
        case .reservedID(let id): return "id \(id) uses the reserved gary. namespace"
        case .builtinOutsideNamespace(let id): return "built-in id \(id) is outside the gary. namespace"
        case .noKinds: return "kinds is empty"
        case .unknownKind(let kind): return "unknown kind \(kind)"
        case .duplicateKind(let kind): return "kind \(kind.rawValue) is listed twice"
        case .missingEntryPoint(let kind): return "no entry point for kind \(kind.rawValue)"
        case .entryPointWithoutKind(let key): return "entry point \(key) has no matching kind"
        case .unsafeEntryPoint(let path): return "entry point \(path) must be a relative .js path inside the plugin"
        case .unknownTopic(let topic): return "unknown subscription \(topic)"
        case .unknownService(let service): return "unknown host service \(service)"
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
    public let uses: [HostService]

    public static func parse(_ data: Data, origin: PluginOrigin) throws -> PluginManifest {
        guard let json = try? JSON.parse(data), case .object = json else { throw ManifestError.invalidJSON }

        func field<T>(_ name: String, _ read: (JSON) -> T?) throws -> T {
            guard let value = json[name] else { throw ManifestError.missingField(name) }
            guard let typed = read(value) else { throw ManifestError.wrongType(name) }
            return typed
        }
        func optional<T>(_ name: String, _ read: (JSON) -> T?, default fallback: T) throws -> T {
            json[name] == nil ? fallback : try field(name, read)
        }
        func strings(_ value: JSON) -> [String]? {
            value.array.flatMap { items in
                let strings = items.compactMap(\.string)
                return strings.count == items.count ? strings : nil
            }
        }

        let schema = try field("schemaVersion", \.number)
        guard schema == Double(schemaVersion) else { throw ManifestError.unsupportedSchemaVersion(Int(schema)) }

        let rawID = try field("id", \.string)
        guard let id = PluginID(rawID) else { throw ManifestError.invalidID(rawID) }
        switch origin {
        case .user where id.isReserved: throw ManifestError.reservedID(id)
        case .builtin where !id.isReserved: throw ManifestError.builtinOutsideNamespace(id)
        default: break
        }

        let name = try field("name", \.string)
        let version = try field("version", \.string)

        let rawKinds = try field("kinds", strings)
        guard !rawKinds.isEmpty else { throw ManifestError.noKinds }
        var kinds: [PluginKind] = []
        for raw in rawKinds {
            guard let kind = PluginKind(rawValue: raw) else { throw ManifestError.unknownKind(raw) }
            guard !kinds.contains(kind) else { throw ManifestError.duplicateKind(kind) }
            kinds.append(kind)
        }

        let rawEntries = try field("entryPoints", \.object)
        var entryPoints: [PluginKind: String] = [:]
        for (key, value) in rawEntries {
            guard let kind = PluginKind(rawValue: key), kinds.contains(kind) else { throw ManifestError.entryPointWithoutKind(key) }
            guard let path = value.string else { throw ManifestError.wrongType("entryPoints.\(key)") }
            guard isSafeRelativeScriptPath(path) else { throw ManifestError.unsafeEntryPoint(path) }
            entryPoints[kind] = path
        }
        if let missing = kinds.first(where: { entryPoints[$0] == nil }) { throw ManifestError.missingEntryPoint(missing) }

        let keepLoaded = try optional("keepLoaded", \.bool, default: false)
        let subscribes = try optional("subscribes", strings, default: []).map { raw in
            guard let topic = Topic(rawValue: raw) else { throw ManifestError.unknownTopic(raw) }
            return topic
        }
        let uses = try optional("uses", strings, default: []).map { raw in
            guard let service = HostService(rawValue: raw) else { throw ManifestError.unknownService(raw) }
            return service
        }

        return PluginManifest(
            id: id, name: name, version: version, kinds: kinds, entryPoints: entryPoints,
            keepLoaded: keepLoaded, subscribes: subscribes, uses: uses
        )
    }
}

func isSafeRelativeScriptPath(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.hasPrefix("/") && !path.hasPrefix("~") && path.hasSuffix(".js") && !path.contains("\0")
        && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
