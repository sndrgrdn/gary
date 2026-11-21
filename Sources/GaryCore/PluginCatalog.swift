import Foundation

public struct PluginBundle: Equatable, Sendable {
    public let manifest: PluginManifest
    public let directory: URL
    public let origin: PluginOrigin

    public static func load(_ directory: URL, origin: PluginOrigin, capabilities: CapabilityNames) throws -> PluginBundle {
        let manifest = try PluginManifest.parse(try Data(contentsOf: try resolveInside(directory, "manifest.json")), origin: origin, capabilities: capabilities)
        let bundle = PluginBundle(manifest: manifest, directory: directory, origin: origin)
        for kind in manifest.kinds { _ = try bundle.entryPoint(kind) }
        return bundle
    }

    public func entryPoint(_ kind: PluginKind) throws -> URL {
        guard let relative = manifest.entryPoints[kind] else { throw ManifestError.missingEntryPoint(kind) }
        return try resolveInside(directory, relative)
    }
}

public struct CatalogProblem: Equatable, Sendable {
    public let directory: URL
    public let reason: String
}

public struct PluginCatalog: Equatable, Sendable {
    public internal(set) var plugins: [PluginID: PluginBundle] = [:]
    public private(set) var problems: [CatalogProblem] = []

    public init() {}

    public static func scan(builtin: URL?, user: URL?, capabilities: CapabilityNames) -> PluginCatalog {
        var catalog = PluginCatalog()
        if let builtin { catalog.add(root: builtin, origin: .builtin, capabilities: capabilities) }
        if let user { catalog.add(root: user, origin: .user, capabilities: capabilities) }
        return catalog
    }

    public var sortedIDs: [PluginID] { plugins.keys.sorted() }

    private mutating func add(root: URL, origin: PluginOrigin, capabilities: CapabilityNames) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !directory.lastPathComponent.hasPrefix("."), isDirectory(directory) else { continue }
            do {
                let bundle = try PluginBundle.load(directory, origin: origin, capabilities: capabilities)
                if let existing = plugins[bundle.manifest.id] {
                    problems.append(CatalogProblem(directory: directory, reason: "duplicate id \(bundle.manifest.id), already at \(existing.directory.path)"))
                } else {
                    plugins[bundle.manifest.id] = bundle
                }
            } catch {
                problems.append(CatalogProblem(directory: directory, reason: "\(error)"))
            }
        }
    }
}

public enum PluginFileError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case symlink(String)
    case notRegularFile(String)

    public var description: String {
        switch self {
        case .missing(let path): return "\(path) does not exist"
        case .symlink(let path): return "\(path) is a symlink"
        case .notRegularFile(let path): return "\(path) is not a regular file"
        }
    }
}

func resolveInside(_ directory: URL, _ relative: String) throws -> URL {
    guard relative == "manifest.json" || isSafeRelativeScriptPath(relative) else { throw ManifestError.unsafeEntryPoint(relative) }
    var url = directory
    let components = relative.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
        url.appendPathComponent(component)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw PluginFileError.missing(relative) }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw PluginFileError.symlink(relative) }
        let isLast = index == components.count - 1
        if isLast ? type != S_IFREG : type != S_IFDIR { throw PluginFileError.notRegularFile(relative) }
    }
    return url
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}
