import Foundation
import GaryCore

let skillUsage: [CommandUsage] = [
    CommandUsage(
        "skill [status|setup|remove|show [topic]]",
        """
        Install the gary skill into Claude Code and agents that read ~/.agents/skills, or print the guide it points to, \
        or one topic of its reference.
        """,
        nil,
    ),
]

struct BundledExample {
    let name: String
    let summary: String
    let manifest: PluginManifest?

    static func all() -> [BundledExample] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Paths.examples, includingPropertiesForKeys: nil)) ?? []
        let capabilities = Capability.names()
        return directories.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { directory in
            let readme = (try? String(contentsOf: directory.appending(path: "README.md"), encoding: .utf8)) ?? ""
            let paragraph = readme.components(separatedBy: "\n\n").dropFirst().first?.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces) ?? ""
            let manifest = try? PluginBundle.load(directory, origin: .user, capabilities: capabilities).manifest
            return BundledExample(name: directory.lastPathComponent, summary: paragraph, manifest: manifest)
        }
    }
}

enum Skill {
    private static let stubVersion = "2"
    private static let stub = """
    ---
    name: gary
    description: Build, install, debug, and verify plugins for Gary, the macOS shell runtime with a bar, panels, overlays, menus, and services in TypeScript. Use the gary CLI to control the running shell.
    metadata:
      gary-stub: "\(stubVersion)"
    ---
    <!-- Installed by "gary skill setup". Remove it with "gary skill remove". -->

    Run `gary skill show` and follow the guide it prints. The guide comes from
    the installed Gary, so it describes the commands available in that version.

    If the command fails, the installed Gary predates the guide. Start with
    `gary ping`, then use `gary help`.

    """

    private struct Destination {
        let agents: String
        let homes: [String]
        let folder: URL
    }

    private static let destinations = [
        Destination(agents: "Claude Code", homes: [".claude"], folder: homeURL.appending(path: ".claude/skills/gary")),
        Destination(
            agents: "Codex, OpenCode, and pi",
            homes: [".agents", ".codex", ".config/opencode", ".pi"],
            folder: homeURL.appending(path: ".agents/skills/gary"),
        ),
    ]

    private static var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private enum State: String {
        case current, outdated, missing, foreign
    }

    static func run(_ words: [String]) -> Int32 {
        if words.count == 2, words[0] == "show" {
            return show(words[1])
        }
        switch words {
        case ["show"]:
            print(guide(theme: nil, examples: BundledExample.all()), terminator: "")
            return 0
        case ["setup"]:
            return setup()
        case ["remove"]:
            return remove()
        case [], ["status"]:
            status()
            return 0
        default:
            fputs("usage: gary \(skillUsage[0].syntax)\n", stderr)
            return 64
        }
    }

    private static func show(_ topic: String) -> Int32 {
        guard let text = reference(topic, theme: try? JSON.parse(Data(contentsOf: Paths.defaultTheme)), examples: BundledExample.all()) else {
            let names = topics(theme: nil).map(\.name) + ["all", "<capability>"]
            fputs("unknown topic \"\(topic)\"; use \(names.joined(separator: ", "))\n", stderr)
            return 64
        }
        print(text, terminator: "")
        return 0
    }

    private static func setup() -> Int32 {
        for destination in destinations {
            let agents = destination.agents
            let folder = destination.folder
            guard found(destination.homes) else {
                print("\(agents): not found")
                continue
            }
            guard state(of: folder) != .foreign else {
                print("\(agents): skipped \(display(folder)), which holds a skill Gary didn't install")
                continue
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(stub.utf8).write(to: folder.appending(path: "SKILL.md"), options: .atomic)
                print("\(agents): installed \(display(folder))")
            } catch {
                fputs("\(agents): failed, \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return 0
    }

    private static func remove() -> Int32 {
        for destination in destinations where [.current, .outdated].contains(state(of: destination.folder)) {
            do {
                try FileManager.default.removeItem(at: destination.folder)
                print("\(destination.agents): removed \(display(destination.folder))")
            } catch {
                fputs("\(destination.agents): failed, \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return 0
    }

    private static func status() {
        for destination in destinations {
            let folder = destination.folder
            print("\(destination.agents): " +
                (found(destination.homes) ? "\(state(of: folder).rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(display(folder))" :
                    "not found"))
        }
    }

    private static func found(_ homes: [String]) -> Bool {
        homes.contains { FileManager.default.fileExists(atPath: homeURL.appending(path: $0).path) }
    }

    private static func state(of folder: URL) -> State {
        guard let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: folder.path) ? .foreign : .missing
        }
        if text == stub {
            return .current
        }
        return text.contains("gary-stub:") ? .outdated : .foreign
    }

    private static func display(_ folder: URL) -> String {
        "~" + folder.path.dropFirst(homeURL.path.count)
    }
}
