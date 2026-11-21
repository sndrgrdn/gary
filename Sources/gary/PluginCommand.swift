import Foundation
import GaryCore

let pluginUsage: [(syntax: String, description: String)] = [
    ("plugin types [path]", "Write gary.d.ts and manifest.schema.json into a plugin folder."),
]

private struct CommandError: Error, CustomStringConvertible {
    let description: String
    var usage = false
    init(_ description: String, usage: Bool = false) {
        self.description = description
        self.usage = usage
    }
}

private struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: [String], flags allowed: Set<String> = [], options: Set<String> = [], count: ClosedRange<Int>) throws {
        var rest = raw[...]
        while let argument = rest.popFirst() {
            if allowed.contains(argument) {
                flags.insert(argument)
            } else if options.contains(argument) {
                guard let value = rest.popFirst() else { throw CommandError("\(argument) needs a value", usage: true) }
                self.options[argument] = value
            } else if argument.hasPrefix("--") {
                throw CommandError("unknown option \(argument)", usage: true)
            } else {
                positional.append(argument)
            }
        }
        guard count.contains(positional.count) else { throw CommandError("wrong number of arguments", usage: true) }
    }
}

func runPlugin(_ arguments: [String]) -> Int32 {
    do {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "types":
            let path = try Arguments(rest, count: 0...1).positional.first ?? "."
            print(try writeTypes(URL(fileURLWithPath: path).standardizedFileURL))
        default: throw CommandError("unknown plugin command", usage: true)
        }
        return 0
    } catch let error as CommandError where error.usage {
        fputs("gary plugin: \(error)\nusage:\n", stderr)
        for (syntax, _) in pluginUsage { fputs("  gary \(syntax)\n", stderr) }
        return 64
    } catch {
        fputs("gary plugin: \(error)\n", stderr)
        return 1
    }
}

private func writeTypes(_ directory: URL) throws -> String {
    let capabilities = try Capability.names()
    var selected = Capability.all
    var topics: [PluginID] = []
    var scope = "every capability"
    if let data = try? Data(contentsOf: directory.appending(path: "manifest.json")) {
        do {
            let manifest = try PluginManifest.parse(data, origin: .user, capabilities: capabilities)
            let names = Set(manifest.uses + manifest.subscribes.map(\.description))
            selected = Capability.all.filter { names.contains($0.name) }
            topics = manifest.subscribes.compactMap { if case .plugin(let id) = $0 { return id } else { return nil } }
            scope = "the uses and subscribes of \(manifest.id)"
        } catch {
            scope = "every capability, since manifest.json is invalid: \(error)"
        }
    }
    let theme = try? JSON.parse(Data(contentsOf: Paths.defaultTheme))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let declarations = PluginTypes.declarations(capabilities: selected.map(\.types), pluginTopics: topics, theme: theme)
    try Data(declarations.utf8).write(to: directory.appending(path: PluginTypes.declarationsFile))
    try Data(PluginTypes.manifestSchema(capabilities).prettyText.utf8).write(to: directory.appending(path: PluginTypes.schemaFile))
    return "wrote \(PluginTypes.declarationsFile) and \(PluginTypes.schemaFile) to \(directory.path) for \(scope)"
}
