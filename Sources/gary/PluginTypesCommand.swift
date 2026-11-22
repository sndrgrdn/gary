import Foundation
import GaryCore

func writeTypes(_ directory: URL) throws -> String {
    let capabilities = Capability.names()
    var selected = Capability.all
    var subscribes = Capability.all.filter { $0.topic != nil }.map { Topic.capability($0.name) }
    var scope = "every capability"
    if let data = try? Data(contentsOf: directory.appending(path: "manifest.json")) {
        do {
            let manifest = try PluginManifest.parse(data, origin: .user, capabilities: capabilities)
            let names = Set(manifest.capabilities)
            selected = Capability.all.filter { names.contains($0.name) }
            subscribes = manifest.topics
            scope = "the uses and subscribes of \(manifest.id)"
        } catch {
            scope = "every capability, since manifest.json is invalid: \(error)"
        }
    }
    let publishers = PluginCatalog.scan(
        builtin: nil,
        user: directory.deletingLastPathComponent(),
        packages: [Paths.userPlugins] + ((try? shellConfig())?.packages ?? []).map(PackageStore.directory),
        capabilities: capabilities,
    )
    func topicType(_ publisher: URL?) -> String {
        guard let publisher, FileManager.default.fileExists(atPath: publisher.appending(path: PluginTypes.topicFile).path) else { return "Json" }
        return PluginTypes.topicImport(from: directory, to: publisher)
    }
    let topics = subscribes.map { topic in
        switch topic {
        case let .capability(name): PluginTypes.TopicType(topic, Capability.all.first { $0.name == name }?.topic?.type ?? "Json")
        case let .plugin(id): PluginTypes.TopicType(topic, topicType(publishers.plugins[id]?.directory))
        }
    }
    let theme = try? JSON.parse(Data(contentsOf: Paths.defaultTheme))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var declarations = PluginTypes.declarations(capabilities: selected.map(\.types), topics: topics, published: topicType(directory), theme: theme)
    if importsEffect(directory) {
        declarations += "\n" + PluginTypes.effectDeclarations
    }
    try Data(declarations.utf8).write(to: directory.appending(path: PluginTypes.declarationsFile))
    try Data(PluginTypes.manifestSchema(capabilities).prettyText.utf8).write(to: directory.appending(path: PluginTypes.schemaFile))
    try Data(PluginScaffold.tsconfig.utf8).write(to: directory.appending(path: PluginScaffold.tsconfigFile))
    return "wrote \(PluginTypes.declarationsFile), \(PluginTypes.schemaFile) and \(PluginScaffold.tsconfigFile) to \(directory.path) for \(scope)"
}

private func importsEffect(_ directory: URL) -> Bool {
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return false }
    let specifiers = ["\"\(PluginBundle.effectModule)\"", "'\(PluginBundle.effectModule)'"]
    for case let url as URL in files {
        if url.lastPathComponent == "node_modules" {
            files.skipDescendants()
        } else if ScriptLanguage(path: url.lastPathComponent) != nil, let text = try? String(contentsOf: url, encoding: .utf8),
                  specifiers.contains(where: text.contains)
        {
            return true
        }
    }
    return false
}
