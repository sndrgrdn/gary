import Foundation
import GaryCore

extension Skill {
    static func themeSection(_ theme: JSON?) -> String {
        func entries(_ value: JSON?) -> String {
            guard let fields = value?.object else { return "- (the theme is not bundled with this binary)" }
            return fields.sorted { $0.key < $1.key }.map { "- `\($0.key)`: `\($0.value.text)`" }.joined(separator: "\n")
        }
        return """
        ## Theme

        Name a style with `style`, and a color with `color` or `background`. The user's `palette.toml` sets the palette colors, such as `accent`, `foreground`, `background`, `green`, and `red`, and `theme.json` maps them to the theme colors below. A color value that is a list uses the first entry that resolves.

        A style holds any of the node style properties. The `surface` style paints panels, overlays, and menus whose `background` is `"solid"`, so a `material` in that style gives every surface that material. The `tooltip` style paints node tooltips.

        Styles:

        \(entries(theme?["styles"]))

        Colors:

        \(entries(theme?["colors"]))

        Fonts, which panels, overlays, and menus use:

        \(entries(theme?["fonts"]))

        Fonts in the bar and its widgets, which replace the fonts of the same name there:

        \(entries(theme?["bar"]?["fonts"]))
        """
    }

    static var capabilitySection: String {
        var lines = [
            "## Capabilities",
            "",
            "Each section gives the manifest entry, the macOS permissions, an example entry file, and the declarations that `gary.d.ts` adds.",
        ]
        for capability in Capability.all {
            var entry: [String] = []
            if capability.install != nil {
                entry.append("`\"uses\": [\"\(capability.name)\"]` for the functions")
            }
            if let topic = capability.topic {
                entry.append("`\"subscribes\": [\"\(capability.name)\"]` for `state.\(capability.name)`, a `\(topic.type)`")
            }
            let permissions = capability.permissions.isEmpty ? "none" : capability.permissions.map { "\($0.name) (`\($0.rawValue)`)" }
                .joined(separator: ", ")
            lines += [
                "", "### \(capability.name)", "", capability.summary, "",
                "- Manifest: \(entry.joined(separator: ", and "))",
                "- macOS permissions: \(permissions)",
                "", "```ts", capability.example.trimmingCharacters(in: .newlines), "```",
                "", "```ts", capability.types.trimmingCharacters(in: .newlines), "```",
            ]
        }
        return lines.joined(separator: "\n")
    }

    static var permissionSection: String {
        var lines = [
            "## Permissions",
            "",
            """
            macOS grants each permission to Gary itself, the app `com.sndrgrdn.gary`, not to the \
            terminal or the agent. `gary permissions` asks the running Gary, starting it if needed, and lists each \
            permission with its state, the capabilities that need it, and the enabled plugins that use them. `gary \
            permissions request <name>` shows the macOS prompt, or opens the System Settings pane where macOS has no \
            prompt or the user refused before. Only the user can approve it, so tell the user what to approve. `gary \
            onboarding` opens Gary's permissions window, the built-in `gary.onboarding` plugin, which lists what the \
            enabled plugins need with an Allow button for each, updates as the user allows them, and offers to restart \
            Gary when a grant needs it. Gary opens it on first launch and whenever an enabled plugin needs a permission it \
            lacks, unless the user closed it with that permission still missing. A plugin reads the same data from the \
            `permissions` capability. A grant shows in `gary permissions` at once, except Screen Recording and Full Disk \
            Access, which can need a restart of Gary. The `permissions` topic reports such a grant as `needsRestart`, and \
            `host.permissions.restart()` restarts Gary. For Full Disk Access, which has no prompt, `gary permissions \
            request full-disk-access` also shows a tile with Gary's icon to drag into the list in System Settings. If Gary \
            runs from a terminal with `gary app`, macOS checks the terminal's permissions instead, and `gary permissions` \
            warns about it.
            """,
            "",
            "| Name | Permission | Capabilities | How Gary asks |",
            "| --- | --- | --- | --- |",
        ]
        for permission in Permission.allCases {
            let users = Capability.all.filter { $0.permissions.contains(permission) }.map { "`\($0.name)`" }
            let asks = switch permission {
            case .accessibility: "the macOS prompt, which offers to open the Settings pane"
            case .bluetooth, .location: "the macOS prompt, or the Settings pane after a refusal"
            case .screenRecording: "the macOS prompt the first time, and the Settings pane"
            case .fullDiskAccess: "the Settings pane, since macOS has no prompt"
            }
            lines.append("| `\(permission.rawValue)` | \(permission.name) | \(users.joined(separator: ", ")) | \(asks) |")
        }
        return lines.joined(separator: "\n")
    }

    static var commandSection: String {
        func list(_ usage: [CommandUsage]) -> String {
            usage.map { "- `gary \($0.syntax)`: \($0.description)" + ($0.example.map { " For example, `\($0)`." } ?? "") }.joined(separator: "\n")
        }
        return """
        ## Commands

        These commands talk to the running Gary:

        \(list(Request.usage))

        These commands work on `~/.config/gary` and the installed app without the running Gary:

        \(list(pluginUsage + skillUsage + appUsage))
        """
    }

    static func exampleSection(_ examples: [BundledExample]) -> String {
        guard !examples.isEmpty
        else { return "## Examples\n\nThis binary has no bundled examples. Scaffold with `gary plugin new <id> --kind <kind>`." }
        let rows = examples.map { example -> String in
            let manifest = example.manifest
            let details = [
                manifest.map { "kinds: " + $0.kinds.map(\.rawValue).joined(separator: ", ") },
                manifest.flatMap { $0.uses.isEmpty ? nil : "uses: " + $0.uses.joined(separator: ", ") },
                manifest.flatMap { $0.topics.isEmpty ? nil : "subscribes: " + $0.topics.map(\.description).joined(separator: ", ") },
            ].compactMap(\.self).joined(separator: "; ")
            return "- `\(example.name)`" + (details.isEmpty ? "" : " (\(details))") + ". \(example.summary)"
        }
        return """
        ## Examples

        Gary.app bundles these examples in `\(Paths.examples.path)`. Gary does not load them. Copy one with `gary plugin new <id> --from <example>`. Gary replaces the example's id with yours in every file, and writes fresh `gary.d.ts` and `manifest.schema.json`. Read an example's files there before you start.

        \(rows.joined(separator: "\n"))
        """
    }
}
