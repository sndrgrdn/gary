import Foundation
import GaryCore

let skillUsage: [(syntax: String, description: String, example: String?)] = [
    ("skill [status|setup|remove|show]", "Install the gary skill into Claude Code and agents that read ~/.agents/skills, or print the guide it points to.", nil),
]

struct BundledExample {
    let name: String
    let summary: String
    let manifest: PluginManifest?

    static func all() -> [BundledExample] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Paths.examples, includingPropertiesForKeys: nil)) ?? []
        let capabilities = try? Capability.names()
        return directories.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { directory in
            let readme = (try? String(contentsOf: directory.appending(path: "README.md"), encoding: .utf8)) ?? ""
            let paragraph = readme.components(separatedBy: "\n\n").dropFirst().first?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
            let manifest = capabilities.flatMap { try? PluginBundle.load(directory, origin: .user, capabilities: $0).manifest }
            return BundledExample(name: directory.lastPathComponent, summary: paragraph, manifest: manifest)
        }
    }
}

enum Skill {
    static func guide(theme: JSON?, examples: [BundledExample]) -> String {
        [
            introduction,
            concepts,
            developLoop,
            reference,
            themeSection(theme),
            "## Core type declarations\n\n`gary plugin types` writes these into `gary.d.ts`, followed by the declarations of each capability the manifest names.\n\n```ts\n\(PluginTypes.declarations(capabilities: [], pluginTopics: [], theme: theme).trimmingCharacters(in: .newlines))\n```",
            capabilitySection,
            permissionSection,
            commandSection,
            exampleSection(examples),
        ].joined(separator: "\n\n") + "\n"
    }

    private static let introduction = """
    # Gary

    Gary is a macOS shell runtime, like Quickshell. It draws a bar along the top of each display, and panels, overlays, and menus, from plugins written in TypeScript or JavaScript. Each plugin returns a tree of nodes, and Gary draws the tree with native views.

    Use this guide to build, install, debug, and verify a Gary plugin. It comes from the installed `gary` command, so it matches that version.

    - Build user plugins in `~/.config/gary/plugins/<id>`. Never edit files inside `Gary.app`.
    - Start from a bundled example that is close to the request: `gary plugin new <id> --from <example>`.
    - Use theme style and color names, such as `style: "dim"` or `color: "accent"`, instead of hex colors, so the plugin follows the user's palette.
    - Check every change against the running Gary with `gary listPlugins`, the log, and a screenshot before you report it done.
    - Ask the user before you grant macOS permissions, install a plugin from someone else, or edit `shell.json` beyond enabling the plugin you built.
    """

    private static let concepts = """
    ## Concepts

    A **plugin** is a folder with a `manifest.json` and one entry file per kind. Its id has two or more dot-separated segments of lowercase letters, digits, and hyphens, such as `you.weather`. The `gary.` namespace is reserved for the built-in plugins.

    A plugin has one or more **kinds**. Each kind runs in its own JavaScriptCore context from its own entry file, so kinds share no variables. They share the manifest, so `uses` and `subscribes` apply to every kind. To share values between kinds, publish them from one kind with `host.publish` and subscribe to the plugin's own id, or keep them in `host.storage`:

    | Kind | Runs as |
    | --- | --- |
    | `bar-widget` | A view in the built-in bar. `shell.json` places it in `bar.left`, `bar.center`, or `bar.right`. |
    | `bar` | A whole bar that replaces the built-in one. |
    | `panel` | A window that `gary summon <id>`, `gary toggle <id>`, or `host.show()` shows. |
    | `overlay` | A panel that covers the whole display above other windows. |
    | `menu` | A focusable panel that takes keys and hides when the user clicks outside it. |
    | `service` | A script with no view. It publishes values for other plugins and answers `gary call`. |

    A **surface** is the window of a panel, overlay, or menu. The module's `surface` export places it. Gary loads a surface when it is shown and stops it when it is hidden, unless the manifest sets `keepLoaded`. `host.show()`, `host.hide()`, and `host.toggle()` act on the plugin's surface from any of its kinds, so a bar widget opens its own plugin's panel with `host.toggle()`.

    A **topic** is a value that Gary keeps in the plugin's `state`. A capability topic, such as `clock` or `battery`, runs only while a plugin subscribes to it. A plugin topic is the last value that another plugin passed to `host.publish`, under that plugin's id. The manifest lists topics in `subscribes`.

    A **capability** adds functions to `host`, a state topic, or both. The manifest lists the functions it wants in `uses` and the topics in `subscribes`. `gary.d.ts` declares only what the manifest asks for. Some capabilities need a macOS permission for Gary.

    The **theme** comes from Gary's built-in `theme.json`, the user's `~/.config/gary/theme.json`, and the palette in `~/.config/gary/palette.toml`. Nodes name theme styles and colors, and `state.theme` holds the resolved colors.

    **Lifecycle.** Gary loads a plugin, runs the entry file once, delivers the current value of each subscribed topic to `onTopic`, and calls `render(state)` once per display, so a surface shows current values on its first render. After each handler, timer, host callback, and topic change, Gary calls `render` again and redraws only what changed. Saving any file in the plugin folder reloads the plugin within about 40 ms. A reload that fails keeps the running version and logs the reason. A call that runs longer than 100 ms stops the plugin. A failed bar widget, bar, or service restarts after 1 second, and a failed surface loads again when it is next shown. After 5 failures in 60 seconds, Gary disables the plugin until its files change.
    """

    private static let developLoop = """
    ## Build a plugin

    1. Pick an id and a starting point. List the bundled examples at the end of this guide. Scaffold from the closest one, or from a kind:

    	```sh
    	gary plugin new you.weather --from load --enable
    	gary plugin new you.launcher --kind menu --enable
    	gary plugin new you.music --kind bar-widget,panel --enable
    	```

    	Gary writes `~/.config/gary/plugins/<id>/` with `manifest.json`, one entry file per kind, `gary.d.ts`, `manifest.schema.json`, `tsconfig.json`, and `README.md`. `--enable` turns the plugin on in `~/.config/gary/shell.json`, and a bar widget goes to the right of the bar. Develop in that folder, because Gary loads and reloads plugins only from `~/.config/gary/plugins`. A folder elsewhere, such as one that `--dir <folder>` creates, runs only after `gary plugin add <folder>` copies it there. Edit the installed copy after that.
    2. Edit `manifest.json`. Add the capabilities you call to `uses` and the topics you read to `subscribes`.
    3. Refresh the types after each change to `uses` or `subscribes`:

    	```sh
    	gary plugin types ~/.config/gary/plugins/you.weather
    	```

    4. Edit the entry files. Keep `module.exports = { ... } satisfies Gary.BarWidget`, or the type of your kind, so TypeScript checks `state` and the node tree.
    5. Type-check, then run the checks Gary runs when it loads plugins:

    	```sh
    	npx -p typescript tsc -p ~/.config/gary/plugins/you.weather
    	gary plugin validate ~/.config/gary/plugins/you.weather
    	```

    	Without `npx`, run `deno check --config tsconfig.json gary.d.ts *.ts` in the plugin folder. The config replaces Deno's own `fetch` and other globals with Gary's, and Deno warns that it ignores some of its options.

    6. Save. Gary reloads the plugin. Verify it as the next section describes.

    ### Write entry files

    - Assign `module.exports`. Gary runs each entry file as a plain script, so `import`, `export`, and `require` fail. Put all code for a kind in its entry file.
    - Gary strips TypeScript types with a bundled copy of sucrase and keeps line numbers. It does not type-check, so run `tsc`.
    - There is no DOM, no `console`, and no Node.js API. Use `host.log` for logging, and `host.exec`, `host.readFile`, and `fetch` through their capabilities.
    - Keep module-level variables for state that survives renders. A reload starts the module again from the top, and `host.storage` keeps values across reloads and restarts.
    - Keep `render` pure and fast. Do slow work in timers or capability promises, store the result in a variable, and let the next render show it.
    - A promise from `host` resolves on the plugin's thread, and Gary renders again after the callback.

    ### Verify and debug

    - `gary listPlugins` prints one line per plugin: id, version, `builtin` or `user`, and one state per kind, such as `bar-widget:running panel:hidden`. The states are:
    	- `running`: a bar widget, bar, or service that runs.
    	- `stopped`: a bar widget, bar, or service between a failure and its restart.
    	- `shown`: a panel, overlay, or menu on screen.
    	- `hidden`: a panel, overlay, or menu that is not loaded. `gary summon` or `host.show()` loads it.
    	- `paused`: a hidden surface that `keepLoaded` keeps running.
    	- `not-in-bar`: an enabled bar widget that no `bar` section in `shell.json` names.
    	- `inactive`: a bar that another enabled bar replaces.
    	- `disabled`: the plugin is not enabled in `shell.json`.
    	- `failed(reason)`, or `disabled(reason)` after 5 failures in 60 seconds.
    - The log is `~/Library/Logs/gary.log` when Gary runs as an app. Plugin lines start with `plugin <id>/<kind>:` for loads and failures, and `plugin <id>:` for `host.log`. Run `grep 'plugin you.weather' ~/Library/Logs/gary.log | tail -n 20` after each save.
    - `gary call <id> <method> [args...]` runs a function from the module's `methods`, loading the plugin first if needed. It prints a string result as is and anything else as JSON. Add a `methods` entry that returns internal state when you need to inspect it.
    - `gary summon <id>`, `gary hide <id>`, and `gary toggle <id>` show and hide a panel, overlay, or menu, as `host.show()`, `host.hide()`, and `host.toggle()` do.
    - `gary action <id> <kind> <action> [payload]` sends `onAction` to a running kind, as a click on a node with that `action` would, and Gary renders again. Pass a number for a slider value or text for an input. Use it to test clicks instead of synthesizing mouse events, which need Accessibility for your terminal. For example, `gary action you.music bar-widget toggle` runs the widget's click handler, and `gary listPlugins` then shows `panel:shown`.
    - `gary reloadPlugins <id>` reloads a plugin from disk. `gary rescanPlugins` finds added and removed plugin folders.
    - `gary doctor` reports private API, permission, plugin, `shell.json`, and theme problems.
    - `gary permissions` shows which macOS permissions Gary has and which enabled plugins need them. A capability that lacks a permission says so in its error or topic value, with the `gary permissions request <name>` command that asks for it.
    - Take a screenshot to check the result. Capture only the rectangle you need with `-R x,y,width,height`, because a full-screen capture includes the user's other windows. `screencapture -x -R 0,0,1728,40 /tmp/bar.png` captures the bar of a display 1728 points wide. The `screens` line in the log gives each display's size in points. Rectangles are in points from the top left of the main display. A Retina PNG has two pixels per point, so halve PNG pixel positions to get points. The bar is `theme.bar.height` points tall, 32 by default. Summon a surface before you capture it, and capture the corner its `anchors` and `margins` place it in. The screenshot needs Screen Recording for the program that runs `screencapture`, not for Gary.
    - When `gary` prints `not running`, start Gary with `open ~/Applications/Gary.app`. To restart Gary, for example after the user grants Screen Recording, run `gary quit` and then `open ~/Applications/Gary.app`.
    """

    private static let reference = """
    ## manifest.json

    | Field | Type | Meaning |
    | --- | --- | --- |
    | `$schema` | string | Optional. `./manifest.schema.json` gives editors completion and checks. |
    | `schemaVersion` | `\(PluginManifest.schemaVersion)` | Required. |
    | `id` | string | Required. The plugin id, such as `you.weather`. |
    | `name`, `version` | string | Required. |
    | `kinds` | array | Required. One or more of \(PluginKind.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")). |
    | `entryPoints` | object | Required. One relative `.ts` or `.js` path per kind, such as `{ "panel": "panel.ts" }`. Symlinks are refused. |
    | `subscribes` | array | Topics that appear in `state` and `onTopic`: capability topics, or other plugins' ids. |
    | `uses` | array | Capabilities that add functions to `host`. |
    | `keepLoaded` | boolean | Keep a panel, overlay, or menu running while it is hidden. |
    | `hotkeys` | array | Global hotkeys, such as `{ "id": "open", "keys": "ctrl+alt+space" }`. Gary calls `onHotkey(id)`. A combination needs `cmd`, `ctrl`, or `alt`, unless its key is `f1` to `f12`. Modifiers are `cmd`, `ctrl`, `alt`, and `shift`. Keys are letters, digits, punctuation, `space`, `return`, `tab`, `delete`, `escape`, the arrows, and `f1` to `f12`. |

    ```json
    {
      "$schema": "./manifest.schema.json",
      "schemaVersion": \(PluginManifest.schemaVersion),
      "id": "you.weather",
      "name": "Weather",
      "version": "0.1.0",
      "kinds": ["bar-widget"],
      "entryPoints": { "bar-widget": "widget.ts" },
      "subscribes": ["clock"],
      "uses": ["network"]
    }
    ```

    ## shell.json

    `~/.config/gary/shell.json` turns plugins on and places bar widgets. `gary plugin enable` and `gary plugin disable` edit it, and Gary applies a saved change at once. Without the file, the bar shows the built-in `gary.battery` and `gary.clock` widgets on the right.

    | Field | Meaning |
    | --- | --- |
    | `bar` | `{ "left": [...], "center": [...], "right": [...] }`, lists of bar widget ids. Naming a widget here enables it. Naming any section replaces the default sections. |
    | `bar.revealMenuBar` | `true` by default: when the pointer reaches the top edge of a display, the bar hides so macOS can reveal its menu bar, and returns when the menu bar hides again. `false` keeps the bar over the macOS menu bar. While a plugin hides the menu bar with the `menubar` capability, the bar stays. |
    | `plugins` | Ids of enabled plugins that are not bar widgets, such as panels and services. |
    | `disabledPlugins` | Ids to turn off, including built-in ones. |
    | `settings` | `{ "<id>": { ... } }`. Each plugin reads its object as `state.settings`. |

    ## Module exports

    | Export | Gary calls it |
    | --- | --- |
    | `render(state)` | After every change, once per display. It returns a node. A service needs no `render`. |
    | `onAction(action, payload, state)` | When the user clicks a node with `action`, moves a slider, or types in an input. |
    | `onKey(key, state)` | When a focused surface gets `up`, `down`, `enter`, `escape`, or `tab`. |
    | `onHotkey(id, state)` | When a manifest hotkey fires. |
    | `onTopic(topic, value, state)` | When a subscribed topic changes, and once per topic at load. |
    | `onMediaKey(event, state)` | When a key that `host.mediakeys.intercept` claimed is pressed. |
    | `methods` | `gary call <id> <method> [args...]` runs one with string arguments. |
    | `surface` | An object, or a function of `state`, that places a panel, overlay, or menu. |

    ## state

    | Field | Value |
    | --- | --- |
    | `settings` | The plugin's object from `settings.<id>` in `shell.json`, or `{}`. |
    | `theme` | `{ mode, colors, palette }`, with colors as hex strings. |
    | `display` | The display being rendered: `{ id, index, main, width, height, notched, notch }`. Only in `render`. |
    | `<capability>` | The value of a subscribed capability topic. The capability sections below give its shape. |
    | `<plugin id>` | The last value that the plugin published. |

    A topic field is `undefined` until its first value arrives, so check it before you use it. After that it always has the declared shape. A topic with `available: false` cannot read its data and gives the cause in `reason`, such as a missing permission. A nullable field is `null` when there is nothing to show. For example, `state.nowplaying.track` is `null` when nothing is playing.

    ## Open a panel from a bar widget

    Give one plugin both kinds, and toggle the panel from the widget in `widget.ts`:

    ```ts
    module.exports = {
      render(state) {
        return { type: "text", text: state.nowplaying?.track?.title ?? "Nothing playing", action: "open" };
      },
      onAction(action) {
        if (action === "open") host.toggle();
      },
    } satisfies Gary.BarWidget;
    ```

    The manifest has `"kinds": ["bar-widget", "panel"]`, an entry point for each, and `"subscribes": ["nowplaying"]`, so the panel's `panel.ts` reads `state.nowplaying` too.

    ## host

    Every plugin has these functions. Capabilities add more.

    | Function | What it does |
    | --- | --- |
    | `host.log(message)` | Writes `plugin <id>: <message>` to Gary's log. |
    | `host.storage.get(key)`, `host.storage.set(key, value)` | Keeps JSON values in `~/Library/Application Support/Gary/storage/<id>.json`. Setting `undefined` deletes the key. |
    | `host.publish(value)` | Publishes a JSON value as the topic named by the plugin's id. |
    | `host.show()`, `host.hide()`, `host.toggle()` | Shows or hides the plugin's surface. |

    `setTimeout`, `setInterval`, `clearTimeout`, and `clearInterval` work as in a browser. An interval is at least 10 ms.

    ## Nodes

    `render` returns a node: a plain object with a `type`. Every node takes `key`, `style`, `action`, and the style properties \(StyleProps.names.map { "`\($0)`" }.joined(separator: ", ")). Numbers are points, except `opacity` from 0 to 1. A property on the node overrides the same property in its `style`.

    | `type` | Own fields | `onAction` payload |
    | --- | --- | --- |
    | `row`, `column` | `children` | `null` |
    | `scroll` | `children`, and `reveal`, the key of a child to keep in view | `null` |
    | `button` | `children`, and `hover`, a style name for the pointer-over state | `null` |
    | `text` | `text`, a string or number | `null` |
    | `icon` | `symbol`, an SF Symbol name such as `battery.75percent` | `null` |
    | `image` | `path` to an image file, absolute, from `~`, or relative to the plugin folder | `null` |
    | `slider` | `value` from 0 to 1 | the new value |
    | `progress` | `value` from 0 to 1 | `null` |
    | `input` | `value`, `placeholder`, `change`, and `submit` | the text. `change` and `submit` name the actions. |
    | `spacer` | none. It fills the free space in a row or column, and a row with a spacer spans the width of its column, so the items after the spacer line up at the trailing edge. | `null` |

    - `width` and `height` give a node exactly that size, padding included, and `minWidth` keeps it at least that wide. A `scroll` grows with its content up to its `height`.
    - `padding` is one number for every side, `[vertical, horizontal]`, or `[top, right, bottom, left]`.
    - `align` places the content of a node that is wider than its content, such as text with a `width`: `"leading"`, `"center"`, or `"trailing"`. It also aligns the lines of wrapped text. A node aligns to `"leading"`, and an icon to `"center"`.
    - `offset` moves a node down by that many points, or up when it is negative, without moving its siblings.
    - `animation` animates what changes inside the node when `render` returns a different tree: `"smooth"`, `"spring"`, or `"none"`, which turns off an animation that an enclosing node set. Sizes, positions, colors, and progress values move, and changed text cross-fades.
    - `material` paints a material behind the node, inside its `radius` and under its `background`: `"vibrant"` blurs what is behind the window, `"glass"` is Liquid Glass, and `"none"` removes a material that the node's `style` sets. Give `background` a translucent color, such as `alpha(panel, 0.4)`, to tint it.
    - A `text` node is exactly as wide as its text and as tall as its lines, with no padding of its own.
    - Give siblings unique `key` values so Gary keeps each child's view, and its state such as hover or typed text, when the order changes.
    - A node with `action` is clickable. Gary calls `onAction(action, payload)`.
    - An `image` path that does not start with `/` or `~` is relative to the plugin folder, so a plugin can ship its own images. A path that ends in `.app` shows that app's icon.
    - Text wraps when its surface is narrower than the text, such as a surface with a fixed `width` or one at the display's edge. Text in a `button` stays on one line.
    - A tree holds at most 1000 nodes and 16 levels.
    - Colors are \(ColorExpr.syntax).

    ## surface

    | Field | Values | Default |
    | --- | --- | --- |
    | `screen` | `"main"`, `"focused"`, `"all"`, or a display index | `"focused"`, the display under the pointer |
    | `anchors` | `{ top, bottom, left, right }` booleans | none, so centered. An overlay anchors to every edge. |
    | `width`, `height` | points or `"fit"`. Gary keeps the surface on its display, so a size larger than the display shrinks to it. | `"fit"` |
    | `margins` | points, or `{ top, bottom, left, right }` | `0` |
    | `layer` | \(SurfaceLayer.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")) | `top`. An overlay or menu uses `overlay`. |
    | `exclusionMode` | `"normal"` keeps clear of the bar, and `"ignore"` covers it | `"normal"`. An overlay uses `"ignore"`. |
    | `clickThrough` | boolean | `false` |
    | `focusable` | boolean. A focusable surface takes keys. | `false`. A menu is focusable. |
    | `background` | `"solid"` paints the theme's `surface` style, including its `material`, with a border and a shadow. `"none"` leaves the window clear for the tree to paint, so a root node with `material` and `radius` gives one surface its own material. | `"solid"` |
    """

    private static func themeSection(_ theme: JSON?) -> String {
        func entries(_ value: JSON?) -> String {
            guard let fields = value?.object else { return "- (the theme is not bundled with this binary)" }
            return fields.keys.sorted().map { "- `\($0)`: `\(fields[$0]!.text)`" }.joined(separator: "\n")
        }
        return """
        ## Theme

        Name a style with `style`, and a color with `color` or `background`. The user's `palette.toml` sets the palette colors, such as `accent`, `foreground`, `background`, `green`, and `red`, and `theme.json` maps them to the theme colors below. A color value that is a list uses the first entry that resolves.

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

    private static var capabilitySection: String {
        var lines = ["## Capabilities", "", "Each section gives the manifest entry, the macOS permissions, an example entry file, and the declarations that `gary.d.ts` adds."]
        for capability in Capability.all {
            var entry: [String] = []
            if capability.install != nil { entry.append("`\"uses\": [\"\(capability.name)\"]` for the functions") }
            if capability.topic != nil { entry.append("`\"subscribes\": [\"\(capability.name)\"]` for `state.\(capability.name)`") }
            let permissions = capability.permissions.isEmpty ? "none" : capability.permissions.map { "\($0.name) (`\($0.rawValue)`)" }.joined(separator: ", ")
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

    private static var permissionSection: String {
        var lines = [
            "## Permissions",
            "",
            "macOS grants each permission to Gary itself, `com.sndrgrdn.gary` at `~/Applications/Gary.app`, not to the terminal or the agent. `gary permissions` asks the running Gary, starting it if needed, and lists each permission with its state, the capabilities that need it, and the enabled plugins that use them. `gary permissions request <name>` shows the macOS prompt, or opens the System Settings pane where macOS has no prompt or the user refused before. Only the user can approve it, so tell the user what to approve. `gary onboarding` opens Gary's permissions window, the built-in `gary.onboarding` plugin, which lists what the enabled plugins need with an Allow button for each, updates as the user allows them, and offers to restart Gary when a grant needs it. Gary opens it on first launch and whenever an enabled plugin needs a permission it lacks, unless the user closed it with that permission still missing. A plugin reads the same data from the `permissions` capability. A grant shows in `gary permissions` at once, except Screen Recording and Full Disk Access, which can need a restart of Gary. The `permissions` topic reports such a grant as `needsRestart`, and `host.permissions.restart()` restarts Gary. For Full Disk Access, which has no prompt, `gary permissions request full-disk-access` also shows a tile with Gary's icon to drag into the list in System Settings. If Gary runs from a terminal with `gary app`, macOS checks the terminal's permissions instead, and `gary permissions` warns about it.",
            "",
            "| Name | Permission | Capabilities | How Gary asks |",
            "| --- | --- | --- | --- |",
        ]
        for permission in Permission.allCases {
            let users = Capability.all.filter { $0.permissions.contains(permission) }.map { "`\($0.name)`" }
            let asks: String
            switch permission {
            case .accessibility: asks = "the macOS prompt, which offers to open the Settings pane"
            case .bluetooth, .location: asks = "the macOS prompt, or the Settings pane after a refusal"
            case .screenRecording: asks = "the macOS prompt the first time, and the Settings pane"
            case .fullDiskAccess: asks = "the Settings pane, since macOS has no prompt"
            }
            lines.append("| `\(permission.rawValue)` | \(permission.name) | \(users.joined(separator: ", ")) | \(asks) |")
        }
        return lines.joined(separator: "\n")
    }

    private static var commandSection: String {
        func list(_ usage: [(syntax: String, description: String, example: String?)]) -> String {
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

    private static func exampleSection(_ examples: [BundledExample]) -> String {
        guard !examples.isEmpty else { return "## Examples\n\nThis binary has no bundled examples. Scaffold with `gary plugin new <id> --kind <kind>`." }
        let rows = examples.map { example -> String in
            let manifest = example.manifest
            let details = [
                manifest.map { "kinds: " + $0.kinds.map(\.rawValue).joined(separator: ", ") },
                manifest.flatMap { $0.uses.isEmpty ? nil : "uses: " + $0.uses.joined(separator: ", ") },
                manifest.flatMap { $0.subscribes.isEmpty ? nil : "subscribes: " + $0.subscribes.map(\.description).joined(separator: ", ") },
            ].compactMap { $0 }.joined(separator: "; ")
            return "- `\(example.name)`" + (details.isEmpty ? "" : " (\(details))") + ". \(example.summary)"
        }
        return """
        ## Examples

        Gary.app bundles these examples in `\(Paths.examples.path)`. Gary does not load them. Copy one with `gary plugin new <id> --from <example>`. Gary replaces the example's id with yours in every file, and writes fresh `gary.d.ts` and `manifest.schema.json`. Read an example's files there before you start.

        \(rows.joined(separator: "\n"))
        """
    }

    private static let stubVersion = "1"
    private static let stub = """
        ---
        name: gary
        description: Build, install, debug, and verify plugins for Gary, the macOS shell runtime with a bar, panels, overlays, menus, and services in TypeScript. Use the gary CLI to control the running shell.
        metadata:
          gary-stub: "\(stubVersion)"
        ---
        <!-- Installed by "gary skill setup". Remove it with "gary skill remove". -->

        Run `gary skill show` and follow the guide it prints. The guide comes from the installed Gary, so it matches that version.

        """

    private static let destinations: [(agents: String, homes: [String], folder: URL)] = [
        ("Claude Code", [".claude"], homeURL.appending(path: ".claude/skills/gary")),
        ("Codex, OpenCode, and pi", [".agents", ".codex", ".config/opencode", ".pi"], homeURL.appending(path: ".agents/skills/gary")),
    ]

    private static var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }

    private enum State: String {
        case current, outdated, missing, foreign
    }

    static func run(_ words: [String]) -> Int32 {
        switch words {
        case ["show"]:
            print(guide(theme: try? JSON.parse(Data(contentsOf: Paths.defaultTheme)), examples: BundledExample.all()), terminator: "")
        case ["setup"]:
            for (agents, homes, folder) in destinations {
                guard found(homes) else {
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
        case ["remove"]:
            for (agents, _, folder) in destinations where [.current, .outdated].contains(state(of: folder)) {
                do {
                    try FileManager.default.removeItem(at: folder)
                    print("\(agents): removed \(display(folder))")
                } catch {
                    fputs("\(agents): failed, \(error.localizedDescription)\n", stderr)
                    return 1
                }
            }
        case [], ["status"]:
            for (agents, homes, folder) in destinations {
                print("\(agents): " + (found(homes) ? "\(state(of: folder).rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(display(folder))" : "not found"))
            }
        default:
            fputs("usage: gary \(skillUsage[0].syntax)\n", stderr)
            return 64
        }
        return 0
    }

    private static func found(_ homes: [String]) -> Bool {
        homes.contains { FileManager.default.fileExists(atPath: homeURL.appending(path: $0).path) }
    }

    private static func state(of folder: URL) -> State {
        guard let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: folder.path) ? .foreign : .missing
        }
        if text == stub { return .current }
        return text.contains("gary-stub:") ? .outdated : .foreign
    }

    private static func display(_ folder: URL) -> String {
        "~" + folder.path.dropFirst(homeURL.path.count)
    }
}
