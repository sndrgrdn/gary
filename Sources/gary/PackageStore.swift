import Foundation
import GaryCore

nonisolated enum PackageStore {
    private static let staging = Paths.packages.appending(path: ".staging")

    static func directory(_ source: PackageSource) -> URL {
        switch source {
        case let .local(url): url
        case .npm, .git: Paths.packages.appending(path: source.managedPath ?? "")
        }
    }

    static func isInstalled(_ source: PackageSource) -> Bool {
        FileManager.default.fileExists(atPath: directory(source).path)
    }

    static func revision(_ source: PackageSource, at directory: URL? = nil) -> String? {
        let directory = directory ?? self.directory(source)
        switch source {
        case .npm: return (try? JSON.parse(Data(contentsOf: directory.appending(path: "package.json"))))?["version"]?.string
        case .git: return try? git(["rev-parse", "--short", "HEAD"], in: directory)
        case .local: return nil
        }
    }

    static func tracking(_ source: PackageSource) -> String {
        switch source {
        case let .npm(_, version):
            switch version {
            case .exact: return "pinned"
            case .latest: return "follows latest"
            case let .tag(tag): return "follows \(tag)"
            }
        case let .git(git):
            let directory = directory(source)
            guard let ref = git.ref else {
                let upstream = (try? self.git(["rev-parse", "--abbrev-ref", "@{upstream}"], in: directory)) ?? "origin/HEAD"
                return "follows \(upstream.replacingOccurrences(of: "origin/", with: ""))"
            }
            return isBranch(ref, in: directory) ? "follows \(ref)" : "pinned"
        case .local: return "local"
        }
    }

    static func stage(_ source: PackageSource) throws -> URL {
        let folder = staging.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: "package")
        do {
            switch source {
            case let .npm(name, version):
                try fetchNpm(name, NpmRelease.resolve(packument(name), name: name, version: version), into: target)
            case let .git(git):
                try self.git(["clone", "--quiet", "--", git.repository, target.path], in: folder)
                if let ref = git.ref {
                    try self.git(["checkout", "--quiet", ref], in: target)
                }
            case .local:
                throw PackageError("a local package loads in place")
            }
        } catch {
            discard(target)
            throw error
        }
        return target
    }

    static func commit(_ staged: URL, as source: PackageSource) throws {
        let target = directory(source)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = staged.deletingLastPathComponent().appending(path: "old")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: old)
        }
        try FileManager.default.moveItem(at: staged, to: target)
        discard(staged)
    }

    static func discard(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    static func install(_ source: PackageSource) throws {
        guard source.managedPath != nil, !isInstalled(source) else { return }
        try commit(stage(source), as: source)
    }

    static func update(_ source: PackageSource) throws -> (from: String?, to: String?) {
        let before = revision(source)
        guard isInstalled(source) else {
            try install(source)
            return (nil, revision(source))
        }
        switch source {
        case let .npm(name, version):
            if case let .exact(exact) = version, exact == before {
                break
            }
            let release = try NpmRelease.resolve(packument(name), name: name, version: version)
            guard release.version != before else { break }
            let staged = staging.appending(path: UUID().uuidString).appending(path: "package")
            do {
                try fetchNpm(name, release, into: staged)
            } catch {
                discard(staged)
                throw error
            }
            try commit(staged, as: source)
        case let .git(git):
            try updateGit(git, in: directory(source))
        case .local:
            break
        }
        return (before, revision(source))
    }

    static func remove(_ source: PackageSource) throws {
        guard source.managedPath != nil, isInstalled(source) else { return }
        var directory = directory(source)
        try FileManager.default.removeItem(at: directory)
        directory.deleteLastPathComponent()
        while directory.path.hasPrefix(Paths.packages.path + "/"),
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
        {
            try FileManager.default.removeItem(at: directory)
            directory.deleteLastPathComponent()
        }
    }

    private static func updateGit(_ source: GitSource, in directory: URL) throws {
        let target: String
        if let ref = source.ref, !isBranch(ref, in: directory) {
            if (try? git(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: directory)) == nil {
                try git(["fetch", "--quiet", "origin", ref], in: directory)
                target = "FETCH_HEAD"
            } else {
                target = "\(ref)^{commit}"
            }
        } else {
            try git(["fetch", "--quiet", "origin"], in: directory)
            target = source.ref.map { "origin/\($0)" } ?? "@{upstream}"
        }
        guard try git(["rev-parse", "HEAD"], in: directory) != git(["rev-parse", target], in: directory) else { return }
        try git(["reset", "--hard", "--quiet", target], in: directory)
    }

    private static func isBranch(_ ref: String, in directory: URL) -> Bool {
        (try? git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(ref)"], in: directory)) != nil
    }

    private static func packument(_ name: String) throws -> JSON {
        guard let url = URL(string: "https://registry.npmjs.org")?.appending(path: name) else { throw PackageError("invalid npm registry URL") }
        return try JSON.parse(download(url, accept: "application/vnd.npm.install-v1+json"))
    }

    private static func fetchNpm(_ name: String, _ release: NpmRelease, into target: URL) throws {
        let data = try download(release.tarball)
        try release.integrity.verify(data)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let archive = target.deletingLastPathComponent().appending(path: "package.tgz")
        try data.write(to: archive)
        do {
            try run("/usr/bin/tar", ["-xzf", archive.path, "-C", target.path, "--strip-components", "1"], in: target)
        } catch {
            throw PackageError("cannot extract \(name)@\(release.version): \(error)")
        }
    }

    private static func download(_ url: URL, accept: String? = nil) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(PackageError("no answer from \(url.absoluteString)"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(PackageError("cannot download \(url.absoluteString): \(error.localizedDescription)"))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(PackageError("\(url.absoluteString) answered HTTP \(http.statusCode)"))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        try run("/usr/bin/env", ["git"] + arguments, in: directory, environment: ["GIT_TERMINAL_PROMPT": "0"])
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], in directory: URL, environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = { (data: Data) in (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard process.terminationStatus == 0 else {
            throw PackageError("\(arguments.first == "git" ? "git \(arguments.dropFirst().first ?? "")" : executable) failed: \(text(message))")
        }
        return text(data)
    }
}
