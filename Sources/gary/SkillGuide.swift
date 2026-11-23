import Foundation
import GaryCore

extension Skill {
    struct Topic {
        let name: String
        let summary: String
        let text: String
    }

    static func guide(theme _: JSON?, examples: [BundledExample]) -> String {
        [introduction, terminology, concepts, developLoop, testing, commonRequests, verification, referenceIndex, exampleSection(examples)]
            .joined(separator: "\n\n") + "\n"
    }

    static func topics(theme: JSON?) -> [Topic] {
        [
            Topic(name: "manifest", summary: "the fields of `manifest.json` and `shell.json`", text: manifestTopic),
            Topic(name: "plugin", summary: "the default export, `state`, and the `host` functions every plugin has", text: pluginTopic),
            Topic(name: "effect", summary: "`gary:effect`, which runs Effect in a plugin, with its declarations", text: effectTopic),
            Topic(name: "nodes", summary: "every node type with its fields and style properties, and the `surface` fields", text: nodesTopic),
            Topic(
                name: "drawing",
                summary: "gradients, rotation, blur, loops, and the `shape`, `chart`, `grid`, and `shader` nodes",
                text: drawingSection,
            ),
            Topic(name: "theme", summary: "the styles, colors, and fonts of the installed theme", text: themeSection(theme)),
            Topic(name: "types", summary: "the core declarations that `gary plugin types` writes into `gary.d.ts`", text: typesTopic(theme)),
            Topic(
                name: "capabilities",
                summary: "every capability with its manifest entry, permissions, example, and declarations",
                text: capabilitySection,
            ),
            Topic(
                name: "permissions",
                summary: "the macOS permissions that capabilities need, and how the user grants them",
                text: permissionSection,
            ),
            Topic(name: "commands", summary: "every `gary` command", text: commandSection),
        ]
    }

    static func reference(_ name: String, theme: JSON?, examples: [BundledExample]) -> String? {
        let topics = topics(theme: theme)
        if name == "all" {
            return ([guide(theme: theme, examples: examples)] + topics.map { $0.text + "\n" }).joined(separator: "\n")
        }
        if let topic = topics.first(where: { $0.name == name }) {
            return topic.text + "\n"
        }
        return Capability.all.first { $0.name == name }.map { capabilityEntry($0).joined(separator: "\n") + "\n" }
    }

    static func typesTopic(_ theme: JSON?) -> String {
        "## Core type declarations\n\n`gary plugin types` writes these into `gary.d.ts`, followed by the declarations of each capability the manifest names.\n\n```ts\n\(PluginTypes.declarations(capabilities: [], topics: [], published: "Json", theme: theme).trimmingCharacters(in: .newlines))\n```"
    }

    static let introduction = """
    # Gary

    Gary is a macOS shell runtime, like Quickshell. It draws a bar along the top of each display, and panels, overlays, and menus, from plugins written in TypeScript or JavaScript. Each plugin returns a tree of nodes, and Gary draws the tree with SwiftUI.

    ## Overview

    This guide covers the common tasks: building a plugin, testing it the way the user would, and reporting the result. It comes from the installed `gary` command, so it matches that version. `gary skill show <topic>` prints the full reference for one topic, as the last sections list.

    - Run the installed `gary` command. It talks to the running Gary. Drive and inspect plugins with its commands, not by synthesizing mouse or key events, which need Accessibility for your terminal, or by screenshots of the whole display.
    - Build user plugins in `~/.config/gary/plugins/<id>`. Never edit files inside `Gary.app`.
    - Start from a bundled example that is close to the request: `gary plugin new <id> --from <example>`.
    - Use theme style and color names, such as `style: "dim"` or `color: "accent"`, instead of hex colors, so the plugin follows the user's palette.
    - Test every change in the running Gary, as Test like the user describes, before you report it done.
    - Ask the user before you grant macOS permissions, install a plugin from someone else, or edit `shell.json` beyond enabling the plugin you built.
    - Other agents may be testing in the same Gary. Don't run `gary quit`, restart Gary, or reinstall it unless the user asks.
    """

    static let terminology = """
    ## Use Gary terminology

    | User term or request | Gary term or command |
    | --- | --- |
    | Widget, bar item, module | A `bar-widget` kind, placed by `bar` in `shell.json` |
    | Bar | The built-in bar, or a `bar` kind that replaces it |
    | Popup, popover, dropdown, window | A `panel`, or a `menu` when it takes keys and hides on a click outside |
    | Launcher, picker, switcher, palette | A `menu` whose `surface` has `background: "backdrop"` |
    | OSD, HUD, banner | An `overlay`, or a second surface of a panel |
    | Daemon, background job, watcher | A `service` kind |
    | Shortcut, keybinding | A manifest `hotkeys` entry, or `host.hotkeys` for keys read from settings |
    | Config, options, preferences | `settings.<id>` in `shell.json`, read as `state.settings` |
    | Open, show, close, toggle | `gary summon`, `gary hide`, `gary toggle`, or `host.show()`, `host.hide()`, `host.toggle()` |
    | Click, type, press, hover, scroll | `gary action`, `gary click`, `gary key`, `gary hover`, `gary scroll` |
    | See how it looks, check the layout | `gary tree` for frames and colors, `gary capture` for a PNG |
    | Logs, console output | `~/Library/Logs/gary.log`, written by `host.log` |
    | Colors, look, appearance | The theme: style and color names that `gary skill show theme` lists |
    """

    static let concepts = """
    ## Concepts

    A **plugin** is a folder with a `manifest.json` and one entry file per kind. Its id has two or more dot-separated segments of lowercase letters, digits, and hyphens, such as `you.weather`. The `gary.` namespace is reserved for the built-in plugins.

    A plugin has one or more **kinds**. Each kind runs in its own JavaScriptCore context from its own entry file, so kinds share no variables. They share the manifest, so `uses` applies to every kind, and so does `subscribes` unless it lists topics per kind. To share values between kinds, ask one kind from another with `host.call({ kind }, method)`, publish them from one kind with `host.publish` and subscribe to the plugin's own id, or keep them in `host.storage`:

    | Kind | Runs as |
    | --- | --- |
    | `bar-widget` | A view in the built-in bar. `shell.json` places it in `bar.left`, `bar.center`, `bar.right`, or `bar.notchLeft`. When `render` returns `null`, the widget and its gap take no space in the bar until it returns a node again. |
    | `bar` | A whole bar that replaces the built-in one. |
    | `panel` | A window that `gary summon <id>`, `gary toggle <id>`, or `host.show()` shows. |
    | `overlay` | A panel that covers the whole display above other windows. |
    | `menu` | A focusable panel that takes keys and hides when the user clicks outside it or presses escape. Each menu surface hides on its own. |
    | `service` | A script with no view. It publishes values for other plugins and answers `gary call`. |

    A **surface** is a window of a panel, overlay, or menu. The `surface` field of the default export places it. To show several windows at once, such as a settings panel and an on-screen display, give `surfaces` instead: an object that maps each surface name to what `surface` takes. A name is lowercase letters, digits, and hyphens. A module with only `surface` has one surface named `main`, and a module that gives both fails to load. The manifest's `surfaces` lists the names of each kind, so Gary knows which kind to load for a name. A kind it does not list has one surface, `main`, and a module whose names differ from its list fails to load. Each surface is shown, placed, focused, and hidden on its own, and `render` draws each one with its name in `state.surface`. Gary loads a kind when it shows its first surface and stops it when its last surface hides, unless the manifest sets `keepLoaded`. `host.show(name)`, `host.hide(name)`, and `host.toggle(name)` act on the plugin's surface with that name, or `main` without one, from any of its kinds, so a bar widget opens its own plugin's panel with `host.toggle()`. Given a surface address instead, a plugin id with an optional colon and surface name such as `you.music:osd`, they act on another plugin's surface, so a bar widget opens a music panel with `host.toggle("you.music")`.

    A **topic** is a value that Gary keeps in the plugin's `state`. A capability topic, such as `clock` or `battery`, runs only while a loaded kind subscribes to it. A plugin topic is the last value that another plugin passed to `host.publish`, under that plugin's id. The manifest lists topics in `subscribes`. A plugin that publishes declares the type of its value in a `topic.ts` at the root of its folder, as `export type Topic = { ... }`. `gary plugin types` then types `host.publish` in that plugin, and `state["<id>"]` and `onTopic` in each plugin that subscribes to it and finds the publisher in a sibling folder, `~/.config/gary/plugins`, or a package in `shell.json`. Without a `topic.ts`, the value is `Json`.

    A **capability** adds functions to `host`, a state topic, or both. The manifest lists the functions it wants in `uses` and the topics in `subscribes`. `gary.d.ts` declares only what the manifest asks for. Some capabilities need a macOS permission for Gary.

    The **theme** comes from Gary's built-in `theme.json`, the user's `~/.config/gary/theme.json`, and the palette in `~/.config/gary/palette.toml`. Nodes name theme styles and colors, and `state.theme` holds the resolved colors, the `spacing` scale: `item`, `section` and `edge`, and the `radius` scale: `control` for rows, buttons and other controls, and `surface` for panels, menus and cards, all in points. Take radii from `state.theme.radius` instead of writing numbers, so a theme rounds every plugin alike. A row inset `spacing.item` inside a surface rounds by `radius.surface - spacing.item`, so its corners follow the surface's.

    **Lifecycle.** Gary loads a plugin, runs the entry file once, delivers the current value of each subscribed topic to `onTopic`, and calls `render(state)` once per display, so a surface shows current values on its first render. After each handler, timer, host callback, and topic change, Gary calls `render` again and redraws only what changed. Saving `manifest.json`, a `.ts`, `.tsx`, `.js`, or `.metal` file, or moving a folder, in the plugin folder reloads the plugin within about 40 ms. Other files, such as images, `gary.d.ts`, and `node_modules`, do not. A reload that fails keeps the running version and logs the reason. A call that runs longer than 100 ms stops the plugin. A failed bar widget, bar, or service restarts after 1 second, and a failed surface loads again when it is next shown. After 5 failures in 60 seconds, Gary disables the plugin until its files change.
    """

    static let developLoop = """
    ## Build a plugin

    1. Pick an id and a starting point. The bundled examples are listed at the end of this guide. Scaffold from the closest one, or from a kind:

    	```sh
    	gary plugin new you.weather --from load
    	gary plugin new you.launcher --kind menu
    	gary plugin new you.music --kind bar-widget,panel
    	```

    	Gary writes `~/.config/gary/plugins/<id>/` with `manifest.json`, one entry file per kind, `gary.d.ts`, `manifest.schema.json`, `tsconfig.json`, and `README.md`, plus a `package.json` with the `effect` types for a service, whose entry file uses `gary:effect`. It turns the plugin on in `~/.config/gary/shell.json`, and a bar widget goes to the bar section that the manifest's `bar` field names, `right` by default. Gary reloads the plugin each time you save its manifest or a source file in that folder. `--dir <folder>` scaffolds elsewhere and records the folder in `packages` in `shell.json`, so Gary loads it in place.
    2. Edit `manifest.json`. Add the capabilities you call to `uses` and the topics you read to `subscribes`.
    3. Refresh the types after each change to `uses` or `subscribes`. This writes `gary.d.ts`, `manifest.schema.json`, and `tsconfig.json`:

    	```sh
    	gary plugin types ~/.config/gary/plugins/you.weather
    	```

    4. Edit the entry files. Keep `export default { ... } satisfies Gary.BarWidget`, or the type of your kind, so TypeScript checks `state` and the node tree.
    5. Type-check, then run the checks Gary runs when it loads plugins:

    	```sh
    	npx -p typescript tsc -p ~/.config/gary/plugins/you.weather
    	gary plugin validate ~/.config/gary/plugins/you.weather
    	```

    	For a plugin that imports `gary:effect`, run `npm install` in its folder first and use `npx tsc -p .`. Without `npx`, run `deno check --config tsconfig.json gary.d.ts *.ts` in the plugin folder. The config replaces Deno's own `fetch` and other globals with Gary's, and Deno warns that it ignores some of its options.

    6. Save. Gary reloads the plugin. Test it as Test like the user describes.

    ### Write entry files

    - Each entry file is an ES module whose default export is an object with the fields that `gary skill show plugin` lists.
    - Import other files of the plugin by relative path, such as `import { parse } from "./parse"`. Gary finds `parse.ts`, `parse.tsx`, `parse.js`, or an `index` file in a `parse` folder. The one other import is `gary:effect`, which `gary skill show effect` describes. Any other import, such as an npm package, fails the load with an error that names it. Each kind loads its own copy of an imported file, once.
    - Write services, timers, `fetch`, and `host.exec` work with Effect from `gary:effect`, and keep `render` synchronous.
    - Gary compiles TypeScript and modules with a bundled copy of sucrase and keeps line numbers. It erases type-only imports. It does not type-check, so run `tsc`.
    - There is no DOM, no `console`, and no Node.js API. Use `host.log` for logging, and `host.exec`, `host.readFile`, and `fetch` through their capabilities.
    - Keep module-level variables for state that survives renders. A reload starts the module again from the top, and `host.storage` keeps values across reloads and restarts.
    - Keep `render` pure and fast. Do slow work in timers or capability promises, store the result in a variable, and let the next render show it.
    - A promise from `host` resolves on the plugin's thread, and Gary renders again after the callback.

    """

    static let testing = """
    ## Test like the user

    Show the plugin, drive it with the commands below as the user would, and inspect what it shows after each step. For example, for a launcher menu with a hotkey:

    ```sh
    gary key you.launcher cmd+space
    gary key you.launcher/menu s a f
    gary hover you.launcher/menu row:safari
    gary tree you.launcher/menu
    gary capture you.launcher/menu /tmp/launcher.png
    gary key you.launcher/menu enter
    gary listPlugins | grep you.launcher
    grep 'plugin you.launcher' ~/Library/Logs/gary.log | tail -n 20
    ```


    - `gary listPlugins` prints one line per plugin: id, version, `builtin` or `user`, and one state per kind, such as `bar-widget:running panel:hidden`. A running kind with several surfaces gives one state per surface instead, such as `panel:main=shown,osd=hidden`. The states are:
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
    - `gary call <id> <method> [args...]` runs a function from the module's `methods`, loading the plugin first if needed. When the function returns a promise, it waits up to 60 seconds for it. It prints a string result as is and anything else as JSON. A thrown error or rejected promise prints its message and exits with status 1. Add a `methods` entry that returns internal state when you need to inspect it.
    - `gary summon <id>`, `gary hide <id>`, and `gary toggle <id>` show and hide a panel, overlay, or menu, as `host.show()`, `host.hide()`, and `host.toggle()` do. Add a colon and a surface name to act on a surface other than `main`, such as `gary summon you.music:osd`.
    - `gary action <id>/<kind> <action> [payload]` clicks the shown node whose `action`, `rightAction`, or `middleAction` has that name, the way the user would. `onAction` gets the node's frame, so a surface with `attach` opens under it, and the command prints the frame as `x,y,width,height` for `screencapture -R`. Pass a number for a slider value. An action no shown node names, such as an input's `change` or `submit`, reaches `onAction` without a frame, with text as its payload. Use it to test clicks instead of synthesizing mouse events, which need Accessibility for your terminal. For example, `gary action you.music/bar-widget toggle` runs the widget's click handler, and `gary listPlugins` then shows `panel:shown`.
    - `gary key <id>[/<kind>] <key>...` presses keys in order, the way the user would, with each key named as `onKey` gets it, such as `a`, `A`, `" "`, `enter`, or `cmd+k`. A key that the plugin holds as a hotkey, such as `alt+space`, presses it: a manifest hotkey runs `onHotkey`, and one from `host.hotkeys` calls its `onPress`. A hotkey that another plugin or app already held when Gary registered it is not the plugin's, so pressing it fails. This is the only way to test a hotkey, since macOS does not fire hotkeys for synthesized key events. Any other key goes to the plugin's focused surface: a focused `input` takes typed characters and sends its `change` action, `enter` sends its `submit` action, and `onKey` gets the keys an input passes on, or every key when no input is focused. So `gary key you.launcher alt+space`, then `gary key you.launcher s a f down enter`, opens the menu, types "saf", moves down, and submits. Use it instead of synthesizing key events, which need Accessibility for your terminal.
    - `gary scroll <id>/<kind> [action] <dy> [--precise]` scrolls by `dy` the way the user would, so `onScroll` gets `event.y` = `dy`. Name a shown node by any of its actions to scroll over it: the innermost node with `scrollAction` under the node's centre takes the scroll, with its frame for `attach`, and with no such node the panel, overlay, or menu gets it. Leave out the action to scroll over the surface. Without `--precise` it is one mouse wheel step of `dy` lines, with `phase` `none`. With `--precise` it is a trackpad gesture of `dy` points: a `began` event with `dy`, then an `ended` event with 0. For example, `gary scroll you.music/bar-widget volume 3`.
    - `gary hover <id>/<kind> <hoverAction> [off]` moves the pointer onto the shown node with that `hoverAction`, so `onAction` gets the name with `true`, the way it does when the user's pointer enters it. With `off` it moves the pointer away, so `onAction` gets `false`. It prints the node's frame like `gary action`.
    - `gary click <id>/<kind> <x> <y>` clicks the left mouse button at a point of the shown surface, in points from its top left corner, the way the user would. Use it for what `gary action` cannot reach, such as a click on empty space that closes a `backdrop` surface. It prints the point on screen.
    - `gary tree <id>/<kind>` prints the nodes the surface shows as an outline, one line per node: its type, key and text, then `@x,y widthxheight` in points from the top left of the surface, and the color, background, opacity, border and font it is drawn with now, hover included. A node in a `scroll` that is out of view, or that has not been laid out, prints without a frame. Use it to check layout and colors exactly, instead of measuring a screenshot.
    - `gary capture <id>/<kind> <file.png>` draws the shown surface into a PNG at the display's scale, so a Retina PNG has two pixels per point. It needs no Screen Recording and shows no other windows, but it leaves out blur and materials, which macOS composites later. Prefer it to `screencapture`.
    - `gary reloadPlugins <id>` reloads a plugin from disk. `gary rescanPlugins` finds added and removed plugin folders.
    - `gary doctor` reports private API, permission, plugin, `shell.json`, and theme problems.
    - `gary permissions` shows which macOS permissions Gary has and which enabled plugins need them. A capability that lacks a permission says so in its error or topic value, with the `gary permissions request <name>` command that asks for it.
    - Check the result with `gary tree` and `gary capture`. When you need what they leave out, such as blur, take a screenshot. Capture only the rectangle you need with `-R x,y,width,height`, because a full-screen capture includes the user's other windows. `screencapture -x -R 0,0,1728,40 /tmp/bar.png` captures the bar of a display 1728 points wide. The `screens` line in the log gives each display's size in points. Rectangles are in points from the top left of the main display. A Retina PNG has two pixels per point, so halve PNG pixel positions to get points. The bar is `theme.bar.height` points tall, 32 by default. Summon a surface before you capture it, and capture the corner its `anchors` and `margins` place it in. The screenshot needs Screen Recording for the program that runs `screencapture`, not for Gary.
    - When `gary` prints `not running`, start Gary with `open -a Gary`. To restart Gary, for example after the user grants Screen Recording, run `gary quit` and then `open -a Gary`.
    """

    static let commonRequests = """
    ## Common requests

    ### Show a command's output in the bar

    Scaffold from the `load` example, which runs a command with `host.exec` on a timer and shows its output:

    ```sh
    gary plugin new you.uptime --from load
    ```

    Change the command and the timer in `widget.ts`. Keep `"uses": ["exec"]` in the manifest. `gary skill show effect` shows the same pattern with `gary:effect`.

    ### Open a panel from a bar widget

    Give one plugin both kinds, and toggle the panel from the widget in `widget.tsx`:

    ```tsx
    export default {
      render(state) {
        return <text action="open">{state.nowplaying?.track?.title ?? "Nothing playing"}</text>;
      },
      onAction(action) {
        if (action === "open") host.toggle();
      },
    } satisfies Gary.BarWidget;
    ```

    The manifest has `"kinds": ["bar-widget", "panel"]`, an entry point for each, and `"subscribes": ["nowplaying"]`, so the panel's `panel.tsx` reads `state.nowplaying` too.

    ### Build a keyboard-driven menu

    A launcher or picker is a `menu` that covers the display with a `backdrop` surface, so a click outside the card hides it. An `input` takes typed text, `onKey` gets the arrows, and `hoverAction` moves the selection to the row under the pointer:

    ```tsx
    let query = "";
    let selected = 0;
    const items = ["Safari", "Mail", "Notes"];
    const shown = () => items.filter((item) => item.toLowerCase().includes(query.toLowerCase()));

    export default {
      surface: { anchors: { top: true, bottom: true, left: true, right: true }, exclusionMode: "ignore", background: "backdrop" },
      render: () => (
        <column key="card" width={480} style="surface" padding={8}>
          <input key="query" value={query} placeholder="Search" change="filter" submit="open" />
          {shown().map((item, index) => (
            <row key={item} action={`pick:${item}`} hoverAction={`hover:${index}`} style={index === selected ? "selected" : undefined}>
              <text>{item}</text>
            </row>
          ))}
        </column>
      ),
      onKey(key) {
        if (key === "down") selected = Math.min(selected + 1, shown().length - 1);
        else if (key === "up") selected = Math.max(selected - 1, 0);
        else return false;
        return true;
      },
      onAction(action, payload) {
        if (action === "filter" && typeof payload === "string") {
          query = payload;
          selected = 0;
        } else if (action.startsWith("hover:") && payload === true) {
          selected = Number(action.slice(6));
        } else if (action === "open" || action.startsWith("pick:")) {
          host.hide();
        }
      },
    } satisfies Gary.Menu;
    ```

    Escape hides a menu unless `onKey` takes it. Test it with `gary key`, `gary hover`, and `gary click` on empty space, as Test like the user describes.

    ### Open a surface with a shortcut from settings

    A manifest hotkey is fixed. To read the keys from settings, register them while the plugin runs with `host.hotkeys`, in a `service` so they work before the menu first loads. The manifest has `"kinds": ["service", "menu"]` and `"uses": ["hotkeys"]`, and the menu's `methods` has `open: () => host.show()`:

    ```ts
    import { Effect, Stream, host, settings } from "gary:effect";

    const keys = typeof settings.key === "string" ? settings.key : "alt+space";

    export default {
      effect: host.hotkeys([keys]).pipe(
        Stream.runForEach(() => host.call({ kind: "menu" }, "open")),
        Effect.catchTag("HostError", (error) => host.log(`${keys}: ${error.message}`)),
      ),
    } satisfies Gary.Service;
    ```

    The user sets the keys in `shell.json` as `"settings": { "you.launcher": { "key": "cmd+space" } }`, and Gary reloads the plugin. `gary key you.launcher cmd+space` presses the hotkey. Gary logs keys that another app already holds, and leaves them unregistered.

    ### Share a value between plugins

    One plugin calls `host.publish(value)`. Another lists the first plugin's id in `subscribes` and reads `state["you.source"]`. Declare the value's type in a `topic.ts` at the root of the publishing plugin, so the subscriber's `gary.d.ts` types it. `gary skill show plugin` covers `host.publish` and `state`.
    """

    static let verification = """
    ## Verify and report the result

    Confirm the result the user asked for, not only that a command ran: the plugin's state in `gary listPlugins`, no new failure in the log, the nodes, frames, and colors in `gary tree`, and the look in a `gary capture` PNG that you read. Read `gary tree` and `gary capture` after the step that should change them, such as a key press or a click.

    Describe the result in the user's terms, such as "The bar shows the uptime at the right" or "The launcher opens with ⌘Space and selects the row under the pointer". Say what you could not check, such as blur, which `gary capture` leaves out, a permission only the user can grant, or a hotkey that another app holds.
    """

    static var referenceIndex: String {
        """
        ## Look up the reference

        This guide covers the common tasks. `gary skill show <topic>` prints the full reference for one topic:

        \(topics(theme: nil).map { "- `\($0.name)`: \($0.summary)." }.joined(separator: "\n"))

        `gary skill show <capability>` prints one capability, such as `gary skill show hotkeys`. The capabilities are \(Capability.all.map { "`\($0.name)`" }.joined(separator: ", ")). `gary skill show all` prints this guide and every topic.

        A plugin's `gary.d.ts`, which `gary plugin types` writes, declares every field and function the plugin can use, and `gary help` lists every command. When this guide and the installed Gary differ, trust `gary.d.ts` and `gary help`.
        """
    }
}
