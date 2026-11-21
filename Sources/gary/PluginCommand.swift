import Foundation
import GaryCore

let pluginUsage: [CommandUsage] = [
    CommandUsage(
        "plugin new <id> [--kind <kind,...> | --from <example>] [--dir <folder>]",
        """
        Scaffold a TypeScript plugin with one or more kinds, or copy a bundled example under a new id, and enable it. \
        It goes into ~/.config/gary/plugins/<id>, or into <folder>, which must not exist yet and which Gary then loads in place as a local package.
        """,
        "gary plugin new you.weather --from load",
    ),
    CommandUsage("plugin validate <path>", "Check a plugin folder with the checks Gary runs when it loads plugins.", nil),
    CommandUsage(
        "plugin install <source> [--yes]",
        """
        Install a package from npm:<name>[@version|@tag], git:<host>/<owner>/<repo>[@ref], a git URL, or a local folder, \
        add it to packages in shell.json, and enable its plugins. It shows each plugin's capabilities and permissions and asks first; \
        --yes skips the question.
        """,
        "gary plugin install git:github.com/you/gary-plugins",
    ),
    CommandUsage(
        "plugin update [<source>]",
        "Bring every package in shell.json, or one, up to date and report each change. A pinned version, tag, or commit stays put.",
        "gary plugin update",
    ),
    CommandUsage(
        "plugin remove <source|id>",
        "Remove a package and drop its plugins from shell.json, or move a plugin in ~/.config/gary/plugins to the Trash.",
        "gary plugin remove git:github.com/you/gary-plugins",
    ),
    CommandUsage("plugin enable <id>", "Turn a plugin on in shell.json; a bar widget goes to the bar section its manifest names.", nil),
    CommandUsage("plugin disable <id>", "Turn a plugin off in shell.json.", nil),
    CommandUsage("plugin list", "List plugins with their version, whether shell.json enables them, their source, and whether it is pinned.", nil),
    CommandUsage(
        "plugin types [path]",
        "Write gary.d.ts and manifest.schema.json into a plugin folder.",
        "gary plugin types ~/.config/gary/plugins/you.weather",
    ),
]

private func dispatch(_ arguments: [String]) throws {
    let rest = Array(arguments.dropFirst())
    switch arguments.first {
    case "new": try newPlugin(Arguments(rest, count: 1...1, options: ["--kind", "--from", "--dir"]))
    case "validate": try validate(Arguments(rest, count: 1...1).positional[0])
    case "install": try install(Arguments(rest, count: 1...1, flags: ["--yes"]))
    case "update": try update(Arguments(rest, count: 0...1).positional.first)
    case "remove": try remove(Arguments(rest, count: 1...1).positional[0])
    case "enable": try enable(pluginID(Arguments(rest, count: 1...1).positional[0]))
    case "disable": try disable(pluginID(Arguments(rest, count: 1...1).positional[0]))
    case "list": _ = try Arguments(rest, count: 0...0); try list()
    case "types":
        let path = try Arguments(rest, count: 0...1).positional.first ?? "."
        try print(writeTypes(URL(fileURLWithPath: path).standardizedFileURL))
    default: throw CommandError("unknown plugin command", usage: true)
    }
}

func runPlugin(_ arguments: [String]) -> Int32 {
    do {
        try dispatch(arguments)
        return 0
    } catch let error as CommandError where error.usage {
        fputs("gary plugin: \(error)\nusage:\n", stderr)
        for usage in pluginUsage {
            fputs("  gary \(usage.syntax)\n", stderr)
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

private func shellConfig() throws -> ShellConfig {
    try FileManager.default.fileExists(atPath: Paths.shellConfig.path) ? ShellConfig
        .parse(JSON.parse(Data(contentsOf: Paths.shellConfig))) : .defaults
}

private func installed(_ packages: [PackageSource]) throws -> PluginCatalog {
    try PluginCatalog.scan(
        builtin: Paths.builtinPlugins, user: Paths.userPlugins, packages: packages.map(PackageStore.directory), capabilities: Capability.names(),
    )
}

private var workingDirectory: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
    let package = arguments.options["--dir"] == nil ? [] : [ShellConfig.Change.declare(.local(directory))]
    try editShellConfig(package + [.enable(id, bar: bundle.manifest.barPlacement)])
    print("enabled \(id)\(bundle.manifest.barPlacement.map { " in bar.\($0.rawValue)" } ?? "") in \(Paths.shellConfig.path)")
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

private func install(_ arguments: Arguments) throws {
    let source = try PackageSource.parse(arguments.positional[0], base: workingDirectory)
    let config = try shellConfig()
    let staged: URL?
    if case let .local(directory) = source {
        guard FileManager.default.fileExists(atPath: directory.path) else { throw CommandError("\(directory.path) does not exist") }
        staged = nil
    } else {
        print("fetching \(source.declaration)")
        staged = try PackageStore.stage(source)
    }
    defer { staged.map(PackageStore.discard) }
    let directory = staged ?? PackageStore.directory(source)
    let bundles = try packagePlugins(directory, of: source)
    try review(bundles, existing: installed(config.packages.filter { $0.identity != source.identity }))
    if !arguments.flags.contains("--yes") {
        guard isatty(STDIN_FILENO) != 0 else { throw CommandError("rerun with --yes to install \(source.declaration)") }
        print(
            "install \(source.declaration) and enable \(bundles.count == 1 ? "this plugin" : "these \(bundles.count) plugins")? [y/N] ",
            terminator: "",
        )
        fflush(stdout)
        guard readLine()?.lowercased().hasPrefix("y") == true else { print("not installed")
            return
        }
    }
    let revision = PackageStore.revision(source, at: directory)
    if let staged {
        try PackageStore.commit(staged, as: source)
    }
    try editShellConfig([.declare(source)] + bundles.map { .install($0.manifest.id, bar: $0.manifest.barPlacement) })
    print("installed \(source.declaration)\(revision.map { " \($0)" } ?? "") in \(PackageStore.directory(source).path)")
    print("enabled \(bundles.map(\.manifest.id.rawValue).joined(separator: ", ")) unless shell.json already placed or disabled them")
    if bundles.contains(where: { bundle in Capability.all.contains { bundle.manifest.capabilities.contains($0.name) && !$0.permissions.isEmpty } }) {
        print("Gary's permissions window asks for what they need; open it any time with: gary onboarding")
    }
}

private func packagePlugins(_ directory: URL, of source: PackageSource) throws -> [PluginBundle] {
    let capabilities = try Capability.names()
    var bundles: [PluginBundle] = []
    for plugin in PluginCatalog.pluginDirectories(inPackage: directory) {
        do {
            try bundles.append(PluginBundle.load(plugin, origin: .user, capabilities: capabilities))
        } catch {
            print("warning: skipping \(plugin.lastPathComponent): \(error)")
        }
    }
    guard !bundles.isEmpty else {
        throw CommandError("\(source.declaration) has no valid plugin: no manifest.json at its root or in a folder directly inside it")
    }
    return bundles
}

private func review(_ bundles: [PluginBundle], existing: PluginCatalog) {
    print("""
    warning: plugins run unsandboxed inside Gary, with your user account's access to files, \
    the network and other programs, and with every macOS permission you granted Gary.
    """)
    for bundle in bundles {
        let manifest = bundle.manifest
        print("\(manifest.id) \(manifest.version) (\(manifest.kinds.map(\.rawValue).joined(separator: ",")))")
        printCapabilities(manifest.capabilities)
        if let other = existing.plugins[manifest.id] {
            print("  warning: \(other.directory.path) already has this id and wins over this package")
        }
    }
}

private func printCapabilities(_ names: [String]) {
    guard !names.isEmpty else { print("  uses no capabilities")
        return
    }
    let width = names.map(\.count).max() ?? 0
    for name in names {
        let permissions = Capability.all.first { $0.name == name }?.permissions.map(\.name) ?? []
        print(
            "  \(name.padding(toLength: width, withPad: " ", startingAt: 0))  macOS permission: \(permissions.isEmpty ? "none" : permissions.joined(separator: ", "))",
        )
    }
}

private func update(_ raw: String?) throws {
    let config = try shellConfig()
    var sources = config.packages
    if let raw {
        let identity = try PackageSource.parse(raw, base: workingDirectory).identity
        sources = sources.filter { $0.identity == identity }
        guard !sources.isEmpty else { throw CommandError("shell.json declares no package \(raw)") }
    }
    guard !sources.isEmpty else { print("shell.json declares no packages")
        return
    }
    var failed = 0
    for source in sources {
        guard source.managedPath != nil else { print("\(source.declaration)\tlocal, loads in place")
            continue
        }
        do {
            let change = try PackageStore.update(source)
            let to = change.to ?? "?"
            print("\(source.declaration)\t" + (change.from == change.to ? "\(to), up to date" : "\(change.from ?? "not installed") -> \(to)"))
        } catch {
            failed += 1
            fputs("gary plugin: \(source.declaration): \(error)\n", stderr)
        }
    }
    guard failed == 0 else { throw CommandError("\(failed) of \(sources.count) packages did not update") }
}

private func remove(_ raw: String) throws {
    let config = try shellConfig()
    if let id = PluginID(raw) {
        let bundle = try installed(config.packages).plugins[id]
        guard bundle?.origin != .builtin else { throw CommandError("\(id) is built into Gary; use gary plugin disable \(id)") }
        if let source = bundle.flatMap({ package(holding: $0.directory, in: config.packages) }) {
            guard PluginCatalog.pluginDirectories(inPackage: PackageStore.directory(source)).count == 1 else {
                throw CommandError(
                    "\(id) is one plugin of \(source.declaration); turn it off with gary plugin disable \(id), or remove the package with gary plugin remove \(source.declaration)",
                )
            }
            try removePackage(source)
            return
        }
        let directory = bundle?.directory ?? Paths.userPlugins.appending(path: id.rawValue)
        if FileManager.default.fileExists(atPath: directory.path) {
            try editShellConfig([.remove(id)])
            var trashed: NSURL?
            try FileManager.default.trashItem(at: directory, resultingItemURL: &trashed)
            print("moved \(directory.path) to \(trashed?.path ?? "the Trash")")
            return
        }
    }
    let identity = try PackageSource.parse(raw, base: workingDirectory).identity
    guard let source = config.packages.first(where: { $0.identity == identity })
    else { throw CommandError("no plugin or package \(raw) in shell.json") }
    try removePackage(source)
}

private func package(holding directory: URL, in packages: [PackageSource]) -> PackageSource? {
    packages.first { (directory.path + "/").hasPrefix(PackageStore.directory($0).resolvingSymlinksInPath().path + "/") }
}

private func removePackage(_ source: PackageSource) throws {
    let capabilities = try Capability.names()
    let ids = PluginCatalog.pluginDirectories(inPackage: PackageStore.directory(source)).compactMap {
        try? PluginBundle.load($0, origin: .user, capabilities: capabilities).manifest.id
    }
    try editShellConfig([.undeclare(source.identity)] + ids.map { .remove($0) })
    try PackageStore.remove(source)
    print("removed \(source.declaration)" + (ids.isEmpty ? "" : " and dropped \(ids.map(\.rawValue).joined(separator: ", ")) from shell.json"))
}

private func enable(_ id: PluginID) throws {
    guard let bundle = try installed(shellConfig().packages).plugins[id] else { throw CommandError("no installed plugin \(id)") }
    let section = bundle.manifest.barPlacement
    try editShellConfig([.enable(id, bar: section)])
    print("enabled \(id)\(section.map { " in bar.\($0.rawValue)" } ?? "") in \(Paths.shellConfig.path)")
}

private func disable(_ id: PluginID) throws {
    guard try installed(shellConfig().packages).plugins[id] != nil else { throw CommandError("no installed plugin \(id)") }
    try editShellConfig([.disable(id)])
    print("disabled \(id) in \(Paths.shellConfig.path)")
}

private func editShellConfig(_ changes: [ShellConfig.Change]) throws {
    let exists = FileManager.default.fileExists(atPath: Paths.shellConfig.path)
    let current = exists ? try JSON.parse(Data(contentsOf: Paths.shellConfig)) : JSON.object([:])
    let next = try changes.reduce(current) { try ShellConfig.applying($1, to: $0) }
    guard next != current else { return }
    try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
    try Data(next.prettyText.utf8).write(to: Paths.shellConfig, options: .atomic)
}

private func list() throws {
    let config = try shellConfig()
    let catalog = try installed(config.packages)
    let enabled = config.resolve(catalog).enabled
    func origin(_ bundle: PluginBundle) -> (source: String, tracking: String) {
        guard bundle.origin == .user else { return ("builtin", "-") }
        guard let source = package(holding: bundle.directory, in: config.packages) else { return (bundle.directory.path, "local") }
        return (source.declaration, PackageStore.tracking(source))
    }
    for bundle in catalog.sortedIDs.compactMap({ catalog.plugins[$0] }) {
        let id = bundle.manifest.id
        let (source, tracking) = origin(bundle)
        print([
            id.rawValue,
            bundle.manifest.version,
            enabled.contains(id) ? "enabled" : "disabled",
            bundle.manifest.kinds.map(\.rawValue).joined(separator: ","),
            source,
            tracking,
        ].joined(separator: "\t"))
    }
    for problem in catalog.problems {
        print("\(problem.directory.path)\t-\tinvalid\t\(problem.reason)")
    }
    for source in config.packages where !PackageStore.isInstalled(source) {
        print("\(source.declaration)\t-\tmissing\tnot installed yet; run gary plugin update")
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
