import Foundation

public enum ScriptLanguage: String, CaseIterable, Sendable {
    case typescript = "ts"
    case tsx
    case javascript = "js"

    public init?(path: String) {
        guard let dot = path.lastIndex(of: "."), let language = Self(rawValue: String(path[path.index(after: dot)...])) else { return nil }
        self = language
    }

    static var extensions: String {
        let names = allCases.map { ".\($0.rawValue)" }
        return names.dropLast().joined(separator: ", ") + ", or " + names[names.count - 1]
    }
}

public struct ImportError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public extension PluginBundle {
    func resolveImport(_ specifier: String, from importer: String) throws -> String {
        let fail = { (reason: String) in ImportError(description: "cannot import \"\(specifier)\" from \(importer): \(reason)") }
        guard specifier.hasPrefix("./") || specifier.hasPrefix("../") else {
            throw fail("Gary resolves only relative paths inside the plugin folder, such as \"./parse\"")
        }
        var parts = importer.split(separator: "/").dropLast().map(String.init)
        for component in specifier.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard parts.popLast() != nil else { throw fail("the path leaves the plugin folder") }
            default: parts.append(String(component))
            }
        }
        let base = parts.joined(separator: "/")
        let index = ScriptLanguage.allCases.map { (base.isEmpty ? "" : base + "/") + "index.\($0.rawValue)" }
        let candidates = ScriptLanguage(path: base) != nil ? [base] : ScriptLanguage.allCases.map { "\(base).\($0.rawValue)" } + index
        for candidate in candidates {
            do {
                _ = try resolveInside(directory, candidate)
                return candidate
            } catch PluginFileError.missing {
                continue
            } catch {
                throw fail("\(error)")
            }
        }
        throw fail("no file \(candidates.joined(separator: ", "))")
    }
}
