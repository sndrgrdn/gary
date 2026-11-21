import CryptoKit
import Foundation

public struct NpmIntegrity: Equatable, Sendable {
    public let digest: Data

    public init(_ text: String) throws {
        let hashes = text.split(separator: " ").filter { $0.hasPrefix("sha512-") }
        guard let hash = hashes.first, let digest = Data(base64Encoded: String(hash.dropFirst(7))), digest.count == 64 else {
            throw PackageError("the registry gives no sha512 integrity, so Gary cannot verify the download")
        }
        self.digest = digest
    }

    public func verify(_ data: Data) throws {
        guard Data(SHA512.hash(data: data)) == digest else {
            throw PackageError("the download does not match the registry's sha512 integrity")
        }
    }
}

public struct NpmRelease: Equatable, Sendable {
    public let version: String
    public let tarball: URL
    public let integrity: NpmIntegrity

    public static func resolve(_ packument: JSON, name: String, version request: NpmVersion) throws -> NpmRelease {
        let version: String
        switch request {
        case let .exact(exact): version = exact
        case .latest, .tag:
            let tag = if case let .tag(tag) = request {
                tag
            } else {
                "latest"
            }
            guard let tagged = packument["dist-tags"]?[tag]?.string else { throw PackageError("\(name) has no dist-tag \(tag)") }
            version = tagged
        }
        guard let dist = packument["versions"]?[version]?["dist"] else { throw PackageError("\(name) has no version \(version)") }
        guard let tarball = dist["tarball"]?.string.flatMap(URL.init(string:)) else {
            throw PackageError("\(name)@\(version) has no tarball")
        }
        return try NpmRelease(version: version, tarball: tarball, integrity: NpmIntegrity(dist["integrity"]?.string ?? ""))
    }
}
