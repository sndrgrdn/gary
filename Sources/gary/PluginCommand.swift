import Foundation
import GaryCore

let pluginUsage: [(syntax: String, description: String, example: String?)] = [
    (
        "plugin new <id> [--kind <kind,...> | --from <example>] [--dir <folder>] [--enable]",
        "Scaffold a TypeScript plugin with one or more kinds, or copy a bundled example under a new id, into ~/.config/gary/plugins/<id>, or into <folder>, which must not exist yet and which Gary does not load until gary plugin add copies it.",
        "gary plugin new you.weather --from load --enable",
    ),
    ("plugin validate <path>", "Check a plugin folder with the checks Gary runs when it loads plugins.", nil),
    (
        "plugin add <git-url|path> [--enable]",
        "Install a plugin from a git repository or a folder without running any of it.",
        "gary plugin add https://github.com/you/gary-weather --enable",
    ),
    ("plugin update <id> [--yes]", "Show what changed upstream, then fast-forward the plugin's checkout.", "gary plugin update you.weather"),
    ("plugin remove <id>", "Move a plugin to the Trash and drop it from shell.json.", nil),
    ("plugin enable <id>", "Turn a plugin on in shell.json; a bar widget goes to the right of the bar.", nil),
    ("plugin disable <id>", "Turn a plugin off in shell.json.", nil),
    ("plugin list", "List installed plugins and whether shell.json enables them.", nil),
    ("plugin types [path]", "Write gary.d.ts and manifest.schema.json into a plugin folder.", "gary plugin types ~/.config/gary/plugins/you.weather"),
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
        case "new": try newPlugin(Arguments(rest, flags: ["--enable"], options: ["--kind", "--from", "--dir"], count: 1...1))
        case "validate": try validate(Arguments(rest, count: 1...1).positional[0])
        case "add": try add(Arguments(rest, flags: ["--enable"], count: 1...1))
        case "update": try update(Arguments(rest, flags: ["--yes"], count: 1...1))
        case "remove": try remove(pluginID(Arguments(rest, count: 1...1).positional[0]))
        case "enable": try enable(pluginID(Arguments(rest, count: 1...1).positional[0]))
        case "disable": try disable(pluginID(Arguments(rest, count: 1...1).positional[0]))
        case "list": _ = try Arguments(rest, count: 0...0); try list()
        case "types":
            let path = try Arguments(rest, count: 0...1).positional.first ?? "."
            try print(writeTypes(URL(fileURLWithPath: path).standardizedFileURL))
        default: throw CommandError("unknown plugin command", usage: true)
        }
        return 0
    } catch let error as CommandError where error.usage {
        fputs("gary plugin: \(error)\nusage:\n", stderr)
        for (syntax, _, _) in pluginUsage {
            fputs("  gary \(syntax)\n", stderr)
        }
        return 64
    } catch {
        fputs("gary plugin: \(error)\n", stderr)
        return 1
    }
}

private func pluginID(_ raw: String) throws -> PluginID {
    guard let id = PluginID(raw) else { throw CommandError("invalid plugin id \"\(raw)\"") }
    return id
}

private func installed() throws -> PluginCatalog {
    try PluginCatalog.scan(builtin: Paths.builtinPlugins, user: Paths.userPlugins, capabilities: Capability.names())
}

private func userPlugin(_ id: PluginID) throws -> URL {
    if let bundle = try installed().plugins[id] {
        guard bundle.origin == .user else { throw CommandError("\(id) is built into Gary; use gary plugin disable \(id)") }
        return bundle.directory
    }
    let directory = Paths.userPlugins.appending(path: id.rawValue)
    guard FileManager.default.fileExists(atPath: directory.path) else { throw CommandError("no installed plugin \(id)") }
    return directory
}

private func newPlugin(_ arguments: Arguments) throws {
    let id = try pluginID(arguments.positional[0])
    guard !id.isReserved else { throw CommandError("\(id) uses the reserved gary. namespace") }
    let example = try arguments.options["--from"].map { name in
        guard arguments.options["--kind"] == nil else { throw CommandError("pass --kind or --from, not both", usage: true) }
        return try bundledExample(name)
    }
    let kinds = try (arguments.options["--kind"] ?? PluginKind.barWidget.rawValue).split(separator: ",").map { raw in
        guard let kind = PluginKind(rawValue: String(raw)) else {
            throw CommandError("unknown kind \(raw); use \(PluginKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }
    let directory = arguments.options["--dir"].map { URL(fileURLWithPath: $0).standardizedFileURL } ?? Paths.userPlugins.appending(path: id.rawValue)
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw CommandError("\(directory.path) already exists") }
    if let example {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: example.directory, to: directory)
        try replace(example.manifest.id.rawValue, with: id.rawValue, in: directory)
    } else {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in PluginScaffold.files(id: id, kinds: kinds) {
            try Data(text.utf8).write(to: directory.appending(path: name))
        }
    }
    _ = try writeTypes(directory)
    let bundle = try PluginBundle.load(directory, origin: .user, capabilities: Capability.names())
    print("created \(id) in \(directory.path)" + (example.map { " from the \($0.directory.lastPathComponent) example" } ?? ""))
    if arguments.flags.contains("--enable") {
        try enable(id)
    }
    print("edit \(bundle.manifest.kinds.compactMap { bundle.manifest.entryPoints[$0] }.joined(separator: ", ")); Gary reloads the plugin on save")
}

private func bundledExample(_ name: String) throws -> PluginBundle {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.examples.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    guard names.contains(name) else {
        throw CommandError("no example \(name); " + (names.isEmpty ? "this gary has no bundled examples" : "use \(names.joined(separator: ", "))"))
    }
    return try PluginBundle.load(Paths.examples.appending(path: name), origin: .user, capabilities: Capability.names())
}

private func replace(_ old: String, with new: String, in directory: URL) throws {
    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
    for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(old) else { continue }
        try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: file, options: .atomic)
    }
}

private func validate(_ path: String) throws {
    let directory = URL(fileURLWithPath: path).standardizedFileURL
    let bundle: PluginBundle
    do {
        bundle = try PluginBundle.load(directory, origin: .user, capabilities: Capability.names())
    } catch {
        throw CommandError("\(directory.path): \(error)")
    }
    let manifest = bundle.manifest
    print("ok \(manifest.id) \(manifest.version) \(manifest.kinds.map(\.rawValue).joined(separator: ","))")
}

private func add(_ arguments: Arguments) throws {
    let source = arguments.positional[0]
    let staging = FileManager.default.temporaryDirectory.appending(path: "gary-plugin-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let checkout = staging.appending(path: "plugin")
    let local = URL(fileURLWithPath: source).standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
        if let top = try? git(["rev-parse", "--show-toplevel"], in: local),
           URL(fileURLWithPath: top).resolvingSymlinksInPath() == local.resolvingSymlinksInPath()
        {
            try git(["clone", "--quiet", "--", local.path, checkout.path], in: staging)
        } else {
            try FileManager.default.copyItem(at: local, to: checkout)
        }
    } else {
        guard !source.hasPrefix("-"), !source.contains("::") else { throw CommandError("refusing \(source): not a git URL or a folder") }
        try git(["clone", "--quiet", "--", source, checkout.path], in: staging)
    }
    let capabilities = try Capability.names()
    let manifest: PluginManifest
    do {
        manifest = try PluginBundle.load(checkout, origin: .user, capabilities: capabilities).manifest
    } catch {
        throw CommandError("\(source) is not a valid plugin: \(error)")
    }
    if let existing = try installed().plugins[manifest.id] {
        throw CommandError("\(manifest.id) is already installed at \(existing.directory.path)")
    }
    let target = Paths.userPlugins.appending(path: manifest.id.rawValue)
    guard !FileManager.default.fileExists(atPath: target.path) else { throw CommandError("\(target.path) already exists") }
    warnUnsandboxed(manifest)
    try FileManager.default.createDirectory(at: Paths.userPlugins, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: checkout, to: target)
    print("installed \(manifest.id) \(manifest.version) in \(target.path)")
    if Capability.all.contains(where: { manifest.capabilities.contains($0.name) && !$0.permissions.isEmpty }) {
        print("when it is enabled, Gary's permissions window asks for what it needs; open it any time with: gary onboarding")
    }
    if arguments.flags.contains("--enable") {
        try enable(manifest.id)
    } else {
        print("read it, then turn it on with: gary plugin enable \(manifest.id)")
    }
}

private func warnUnsandboxed(_ manifest: PluginManifest) {
    print("""
    warning: plugins run unsandboxed inside Gary, with your user account's access to files, \
    the network and other programs, and with every macOS permission you granted Gary.
    """)
    guard !manifest.capabilities.isEmpty else { print("\(manifest.id) uses no capabilities")
        return
    }
    print("\(manifest.id) uses these capabilities in uses and subscribes:")
    printCapabilities(manifest.capabilities)
}

private func printCapabilities(_ names: [String]) {
    let width = names.map(\.count).max() ?? 0
    for name in names {
        let permissions = Capability.all.first { $0.name == name }?.permissions.map(\.name) ?? []
        print(
            "  \(name.padding(toLength: width, withPad: " ", startingAt: 0))  macOS permission: \(permissions.isEmpty ? "none" : permissions.joined(separator: ", "))",
        )
    }
}

private func update(_ arguments: Arguments) throws {
    let id = try pluginID(arguments.positional[0])
    let directory = try userPlugin(id)
    guard (try? git(["rev-parse", "--is-inside-work-tree"], in: directory)) == "true" else { throw CommandError("\(id) was not installed from git") }
    guard try git(["status", "--porcelain"], in: directory).isEmpty
    else { throw CommandError("\(id) has local changes; commit or discard them first") }
    try git(["fetch", "--quiet"], in: directory)
    let head = try git(["rev-parse", "HEAD"], in: directory)
    let upstream = try git(["rev-parse", "@{upstream}"], in: directory)
    guard head != upstream else { print("\(id) is up to date")
        return
    }
    guard (try? git(["merge-base", "--is-ancestor", "HEAD", upstream], in: directory)) != nil else {
        throw CommandError("\(id) cannot fast-forward to \(upstream.prefix(12))")
    }
    try show(["log", "--oneline", "HEAD..\(upstream)"], in: directory)
    try show(["diff", "--stat", "HEAD", upstream], in: directory)
    try show(["diff", "--no-ext-diff", "--no-textconv", "HEAD", upstream], in: directory)

    let staging = FileManager.default.temporaryDirectory.appending(path: "gary-plugin-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: staging) }
    let tree = staging.appending(path: "tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    let index = staging.appending(path: "index").path
    try git(["read-tree", "--index-output=\(index)", upstream], in: directory)
    try git(["checkout-index", "--all", "--prefix=\(tree.path)/"], in: directory, environment: ["GIT_INDEX_FILE": index])
    let capabilities = try Capability.names()
    let next: PluginManifest
    do {
        next = try PluginBundle.load(tree, origin: .user, capabilities: capabilities).manifest
    } catch {
        throw CommandError("not updating \(id): \(upstream.prefix(12)) is not a valid plugin: \(error)")
    }
    guard next.id == id else { throw CommandError("not updating \(id): \(upstream.prefix(12)) changes its id to \(next.id)") }
    let current = (try? PluginBundle.load(directory, origin: .user, capabilities: capabilities))?.manifest
    let added = next.capabilities.filter { !(current?.capabilities ?? []).contains($0) }
    if !added.isEmpty {
        print("warning: this update also uses:")
        printCapabilities(added)
    }

    if !arguments.flags.contains("--yes") {
        guard isatty(STDIN_FILENO) != 0 else { throw CommandError("rerun with --yes to apply this update") }
        print("apply this update to \(id)? [y/N] ", terminator: "")
        fflush(stdout)
        guard readLine()?.lowercased().hasPrefix("y") == true else { print("not updated")
            return
        }
    }
    try git(["merge", "--ff-only", "--quiet", upstream], in: directory)
    print("updated \(id) \(current?.version ?? "?") -> \(next.version)")
}

private func remove(_ id: PluginID) throws {
    let directory = try userPlugin(id)
    try editShellConfig(.remove(id))
    var trashed: NSURL?
    try FileManager.default.trashItem(at: directory, resultingItemURL: &trashed)
    print("moved \(directory.path) to \(trashed?.path ?? "the Trash")")
}

private func enable(_ id: PluginID) throws {
    guard let bundle = try installed().plugins[id] else { throw CommandError("no installed plugin \(id)") }
    let inBar = bundle.manifest.kinds.contains(.barWidget)
    try editShellConfig(.enable(id, inBar: inBar))
    print("enabled \(id)\(inBar ? " in the bar" : "") in \(Paths.shellConfig.path)")
}

private func disable(_ id: PluginID) throws {
    guard try installed().plugins[id] != nil else { throw CommandError("no installed plugin \(id)") }
    try editShellConfig(.disable(id))
    print("disabled \(id) in \(Paths.shellConfig.path)")
}

private func editShellConfig(_ change: ShellConfig.Change) throws {
    let exists = FileManager.default.fileExists(atPath: Paths.shellConfig.path)
    let current = exists ? try JSON.parse(Data(contentsOf: Paths.shellConfig)) : JSON.object([:])
    let next = try ShellConfig.applying(change, to: current)
    guard next != current else { return }
    try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
    try Data(next.prettyText.utf8).write(to: Paths.shellConfig, options: .atomic)
}

private func list() throws {
    let catalog = try installed()
    let config = try FileManager.default.fileExists(atPath: Paths.shellConfig.path)
        ? ShellConfig.parse(JSON.parse(Data(contentsOf: Paths.shellConfig))) : ShellConfig.defaults
    let enabled = config.resolve(catalog).enabled
    for id in catalog.sortedIDs {
        let bundle = catalog.plugins[id]!
        let source = bundle.origin == .builtin ? "builtin" : (try? git(["remote", "get-url", "origin"], in: bundle.directory)) ?? bundle.directory
            .path
        print([
            id.rawValue,
            bundle.manifest.version,
            enabled.contains(id) ? "enabled" : "disabled",
            bundle.manifest.kinds.map(\.rawValue).joined(separator: ","),
            source,
        ].joined(separator: "\t"))
    }
    for problem in catalog.problems {
        print("\(problem.directory.lastPathComponent)\t-\tinvalid\t\(problem.reason)")
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
            topics = manifest.subscribes.compactMap {
                if case let .plugin(id) = $0 {
                    id
                } else {
                    nil
                }
            }
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

@discardableResult
private func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
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
    guard process.terminationStatus == 0 else {
        throw CommandError(
            "git \(arguments.first ?? "") failed: \(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))",
        )
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func show(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "--no-pager", "-c", "color.ui=auto"] + arguments
    process.currentDirectoryURL = directory
    try process.run()
    process.waitUntilExit()
}
