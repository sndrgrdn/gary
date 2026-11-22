import Foundation

public struct PluginBundle: Equatable, Sendable {
    public let manifest: PluginManifest
    public let directory: URL
    public let origin: PluginOrigin

    public static func load(_ directory: URL, origin: PluginOrigin, capabilities: CapabilityNames) throws -> PluginBundle {
        let manifest = try PluginManifest.parse(
            Data(contentsOf: resolveInside(directory, "manifest.json")),
            origin: origin,
            capabilities: capabilities,
        )
        let bundle = PluginBundle(manifest: manifest, directory: directory, origin: origin)
        for kind in manifest.kinds {
            _ = try bundle.entryPoint(kind)
        }
        return bundle
    }

    public func entryPoint(_ kind: PluginKind) throws -> String {
        guard let relative = manifest.entryPoints[kind] else { throw ManifestError.missingEntryPoint(kind) }
        _ = try resolveInside(directory, relative)
        return relative
    }
}

public struct CatalogProblem: Equatable, Sendable {
    public let directory: URL
    public let reason: String
}

public struct PluginCatalog: Equatable, Sendable {
    public internal(set) var plugins: [PluginID: PluginBundle]
    public private(set) var problems: [CatalogProblem]

    public init() {
        plugins = [:]
        problems = []
    }

    public static func scan(builtin: URL?, user: URL?, packages: [URL], capabilities: CapabilityNames) -> PluginCatalog {
        var catalog = PluginCatalog()
        if let builtin {
            catalog.add(children(of: builtin), origin: .builtin, capabilities: capabilities)
        }
        if let user {
            catalog.add(children(of: user), origin: .user, capabilities: capabilities)
        }
        for package in packages {
            catalog.add(pluginDirectories(inPackage: package), origin: .user, capabilities: capabilities)
        }
        return catalog
    }

    public static func pluginDirectories(inPackage root: URL) -> [URL] {
        let root = root.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: root.appending(path: "manifest.json").path) {
            return [root]
        }
        return children(of: root).filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
    }

    public var sortedIDs: [PluginID] {
        plugins.keys.sorted()
    }

    private static func children(of root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") && isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private mutating func add(_ directories: [URL], origin: PluginOrigin, capabilities: CapabilityNames) {
        for directory in directories {
            do {
                let bundle = try PluginBundle.load(directory, origin: origin, capabilities: capabilities)
                if let existing = plugins[bundle.manifest.id] {
                    problems.append(CatalogProblem(
                        directory: directory,
                        reason: "duplicate id \(bundle.manifest.id), already at \(existing.directory.path)",
                    ))
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
        case let .missing(path): "\(path) does not exist"
        case let .symlink(path): "\(path) is a symlink"
        case let .notRegularFile(path): "\(path) is not a regular file"
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
        if type == S_IFLNK {
            throw PluginFileError.symlink(relative)
        }
        let isLast = index == components.count - 1
        if isLast ? type != S_IFREG : type != S_IFDIR {
            throw PluginFileError.notRegularFile(relative)
        }
    }
    return url
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}
