import Foundation

public struct PackageError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct PackageIdentity: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String {
        rawValue
    }
}

public enum NpmVersion: Hashable, Sendable {
    case latest
    case exact(String)
    case tag(String)
}

public struct GitSource: Hashable, Sendable {
    public let repository: String
    public let host: String
    public let path: String
    public let ref: String?
}

public enum PackageSource: Hashable, Sendable {
    case npm(name: String, version: NpmVersion)
    case git(GitSource)
    case local(URL)

    public static func parse(_ raw: String, base: URL?) throws -> PackageSource {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw PackageError("empty package source") }
        if text.hasPrefix("npm:") {
            return try parseNpm(String(text.dropFirst(4)))
        }
        if text.hasPrefix("git:") {
            return try .git(parseGit(String(text.dropFirst(4)), shorthand: true))
        }
        if ["https://", "http://", "ssh://", "git://"].contains(where: { text.lowercased().hasPrefix($0) }) {
            return try .git(parseGit(text, shorthand: false))
        }
        return try .local(parseLocal(text, base: base))
    }

    public var identity: PackageIdentity {
        switch self {
        case let .npm(name, _): PackageIdentity(rawValue: "npm:\(name)")
        case let .git(git): PackageIdentity(rawValue: "git:\(git.host)/\(git.path)")
        case let .local(url): PackageIdentity(rawValue: "local:\(url.path)")
        }
    }

    public var declaration: String {
        switch self {
        case let .npm(name, version):
            switch version {
            case .latest: "npm:\(name)"
            case let .exact(value), let .tag(value): "npm:\(name)@\(value)"
            }
        case let .git(git):
            (git.repository == "https://\(git.host)/\(git.path)" ? "git:\(git.host)/\(git.path)"
                : git.repository.contains("://") ? git.repository : "git:\(git.repository)") + (git.ref.map { "@\($0)" } ?? "")
        case let .local(url): url.path
        }
    }

    public var managedPath: String? {
        switch self {
        case let .npm(name, _): "npm/\(name)"
        case let .git(git): "git/\(git.host)/\(git.path)"
        case .local: nil
        }
    }

    private static func parseNpm(_ spec: String) throws -> PackageSource {
        let separator = spec.dropFirst().firstIndex(of: "@")
        let name = String(separator.map { spec[..<$0] } ?? spec[...])
        guard name.count <= 214, name.wholeMatch(of: /(@[a-z0-9~-][a-z0-9._~-]*\/)?[a-z0-9~-][a-z0-9._~-]*/) != nil else {
            throw PackageError("invalid npm package name \"\(name)\"")
        }
        guard let separator else { return .npm(name: name, version: .latest) }
        let version = String(spec[spec.index(after: separator)...])
        if version.wholeMatch(of: /\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?/) != nil {
            return .npm(name: name, version: .exact(version))
        }
        if version.isEmpty || version.contains(/[\s^~<>=*|]/) || version.contains(/^[vV]?\d/) || ["x", "X"].contains(version) {
            throw PackageError("npm version \"\(version)\" is a range; use an exact version such as 1.2.3 or a dist-tag such as latest")
        }
        guard version.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil else { throw PackageError("invalid npm dist-tag \"\(version)\"") }
        return .npm(name: name, version: .tag(version))
    }

    private static func parseGit(_ text: String, shorthand: Bool) throws -> GitSource {
        let repository: String
        let host: String
        var path: String
        if let scp = text.wholeMatch(of: /git@([^:\/]+):(.+)/), shorthand {
            host = String(scp.1)
            path = String(scp.2)
            repository = "git@\(host):"
        } else if text.contains("://") {
            guard let components = URLComponents(string: text), let name = components.host, !name.isEmpty else {
                throw PackageError("invalid git URL \(text)")
            }
            host = name
            path = components.path
            var base = components
            base.path = ""
            repository = (base.string ?? "") + "/"
        } else if shorthand, let slash = text.firstIndex(of: "/") {
            host = String(text[..<slash])
            path = String(text[text.index(after: slash)...])
            guard host.contains(".") || host == "localhost"
            else { throw PackageError("git source \(text) needs a host, such as github.com/owner/repo") }
            repository = "https://\(host)/"
        } else {
            throw PackageError("invalid git source \(text); use git:<host>/<owner>/<repo>[@ref] or a git URL")
        }
        path = path.trimmingPrefix("/").description
        var ref: String?
        if let at = path.firstIndex(of: "@") {
            ref = String(path[path.index(after: at)...])
            path = String(path[..<at])
            guard ref?.isEmpty == false else { throw PackageError("git source \(text) has an empty ref") }
        }
        let clonePath = path
        if path.hasSuffix(".git") {
            path = String(path.dropLast(4))
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
              !host.contains("/"), !text.contains("\0"), !text.contains("\\")
        else { throw PackageError("git source \(text) needs an owner and a repository, such as github.com/owner/repo") }
        if let ref, ref.hasPrefix("-") || ref.contains("..") || ref.contains(":") {
            throw PackageError("invalid git ref \(ref)")
        }
        return GitSource(repository: repository + clonePath, host: host, path: path, ref: ref)
    }

    private static func parseLocal(_ text: String, base: URL?) throws -> URL {
        var path = text
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { throw PackageError("invalid file URL \(text)") }
            path = url.path
        }
        path = NSString(string: path).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        guard let base else { throw PackageError("local package \(text) must be an absolute path or start with ~/") }
        return base.appending(path: path).standardizedFileURL
    }
}
