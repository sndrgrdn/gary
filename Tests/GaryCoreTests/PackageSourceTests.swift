import Foundation
@testable import GaryCore
import Testing

struct PackageSourceTests {
    private let cwd = URL(fileURLWithPath: "/work/here")

    private func parse(_ raw: String) throws -> PackageSource {
        try PackageSource.parse(raw, base: cwd)
    }

    @Test func `npm sources carry A name and an exact version A dist tag or latest`() throws {
        #expect(try parse("npm:gary-weather") == .npm(name: "gary-weather", version: .latest))
        #expect(try parse("npm:@you/gary-weather@1.2.3") == .npm(name: "@you/gary-weather", version: .exact("1.2.3")))
        #expect(try parse("npm:gary-weather@next") == .npm(name: "gary-weather", version: .tag("next")))
        #expect(try parse("npm:gary-weather@1.0.0-beta.1").declaration == "npm:gary-weather@1.0.0-beta.1")
    }

    @Test func `npm ranges and bad names are refused`() {
        for raw in ["npm:a@^1.2.3", "npm:a@~1.2", "npm:a@1", "npm:a@1.x", "npm:a@>=1.0.0", "npm:a@*", "npm:a@", "npm:Bad", "npm:"] {
            #expect(throws: PackageError.self, "\(raw)") { try parse(raw) }
        }
    }

    @Test func `git sources and https URLs share an identity without the ref`() throws {
        let short = try parse("git:github.com/sndrgrdn/gary-plugins")
        guard case let .git(git) = short else { Issue.record("not git")
            return
        }
        #expect(git == GitSource(repository: "https://github.com/sndrgrdn/gary-plugins", host: "github.com", path: "sndrgrdn/gary-plugins", ref: nil))
        let identities = try [
            "git:github.com/sndrgrdn/gary-plugins@v1",
            "https://github.com/sndrgrdn/gary-plugins.git",
            "git:git@github.com:sndrgrdn/gary-plugins",
        ]
        .map { try parse($0).identity }
        #expect(identities.allSatisfy { $0 == short.identity })
        #expect(short.identity.rawValue == "git:github.com/sndrgrdn/gary-plugins")
        #expect(short.managedPath == "git/github.com/sndrgrdn/gary-plugins")
        #expect(try parse("https://github.com/you/repo@abc123").declaration == "git:github.com/you/repo@abc123")
        #expect(try parse("git:git@github.com:you/repo@v2").declaration == "git:git@github.com:you/repo@v2")
    }

    @Test func `git sources need A host an owner and A repository`() {
        for raw in [
            "git:github/you/repo",
            "git:github.com/repo",
            "git:github.com/you/../x",
            "https://github.com/you/repo@",
            "git:github.com/you/repo@-x",
        ] {
            #expect(throws: PackageError.self, "\(raw)") { try parse(raw) }
        }
    }

    @Test func `local paths resolve against the base and home and are identified by the absolute path`() throws {
        #expect(try parse("./pkg/../plugins") == .local(URL(fileURLWithPath: "/work/here/plugins")))
        #expect(try parse("/abs/x/") == .local(URL(fileURLWithPath: "/abs/x")))
        #expect(try parse("file:///abs/x") == .local(URL(fileURLWithPath: "/abs/x")))
        #expect(try parse("~/plugins") == .local(URL(fileURLWithPath: NSHomeDirectory() + "/plugins")))
        #expect(try parse("/abs/x").identity.rawValue == "local:/abs/x")
        #expect(try parse("/abs/x").managedPath == nil)
        #expect(throws: PackageError.self) { try PackageSource.parse("./plugins", base: nil) }
    }
}

struct NpmReleaseTests {
    private let integrity = "sha512-QFMtBKYL7qISo31z27ZQpFR0iA2ER3gM5ppyr+KMxhtmf63Esfbytf6VMikOrRzrqHjXfc21PNxE6JxbRpz+Uw=="

    private var packument: JSON {
        get throws {
            try JSON.parse("""
            {
              "name": "gary-weather",
              "dist-tags": { "latest": "1.1.0", "next": "2.0.0-beta.1" },
              "versions": {
                "1.0.0": { "dist": { "tarball": "https://r.example/gary-weather-1.0.0.tgz", "integrity": "\(integrity)" } },
                "1.1.0": { "dist": { "tarball": "https://r.example/gary-weather-1.1.0.tgz", "integrity": "sha1-abc \(integrity)" } },
                "2.0.0-beta.1": { "dist": { "tarball": "https://r.example/gary-weather-2.0.0-beta.1.tgz", "shasum": "abc" } }
              }
            }
            """)
        }
    }

    @Test func `resolves an exact version A dist tag or latest to its tarball`() throws {
        #expect(try NpmRelease.resolve(packument, name: "gary-weather", version: .latest).version == "1.1.0")
        #expect(try NpmRelease.resolve(packument, name: "gary-weather", version: .exact("1.0.0")).tarball
            .lastPathComponent == "gary-weather-1.0.0.tgz")
        #expect(throws: PackageError.self) { try NpmRelease.resolve(packument, name: "gary-weather", version: .exact("9.9.9")) }
        #expect(throws: PackageError.self) { try NpmRelease.resolve(packument, name: "gary-weather", version: .tag("beta")) }
    }

    @Test func `a release without sha512 integrity is refused`() {
        #expect(throws: PackageError.self) { try NpmRelease.resolve(packument, name: "gary-weather", version: .tag("next")) }
    }

    @Test func `verifies the download against the sha512 integrity`() throws {
        let release = try NpmRelease.resolve(packument, name: "gary-weather", version: .latest)
        try release.integrity.verify(Data("gary tarball".utf8))
        #expect(throws: PackageError.self) { try release.integrity.verify(Data("gary tarball!".utf8)) }
    }
}
