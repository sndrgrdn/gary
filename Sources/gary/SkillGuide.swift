import Foundation
import GaryCore

extension Skill {
    static func guide(theme: JSON?, examples: [BundledExample]) -> String {
        [
            introduction,
            concepts,
            developLoop,
            reference,
            drawingSection,
            themeSection(theme),
            "## Core type declarations\n\n`gary plugin types` writes these into `gary.d.ts`, followed by the declarations of each capability the manifest names.\n\n```ts\n\(PluginTypes.declarations(capabilities: [], topics: [], published: "Json", theme: theme).trimmingCharacters(in: .newlines))\n```",
            capabilitySection,
            permissionSection,
            commandSection,
            exampleSection(examples),
        ].joined(separator: "\n\n") + "\n"
    }

    static let introduction = """
    # Gary

    Gary is a macOS shell runtime, like Quickshell. It draws a bar along the top of each display, and panels, overlays, and menus, from plugins written in TypeScript or JavaScript. Each plugin returns a tree of nodes, and Gary draws the tree with SwiftUI.

    Use this guide to build, install, debug, and verify a Gary plugin. It comes from the installed `gary` command, so it matches that version.

    - Build user plugins in `~/.config/gary/plugins/<id>`. Never edit files inside `Gary.app`.
    - Start from a bundled example that is close to the request: `gary plugin new <id> --from <example>`.
    - Use theme style and color names, such as `style: "dim"` or `color: "accent"`, instead of hex colors, so the plugin follows the user's palette.
    - Check every change against the running Gary with `gary listPlugins`, the log, and a screenshot before you report it done.
    - Ask the user before you grant macOS permissions, install a plugin from someone else, or edit `shell.json` beyond enabling the plugin you built.
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

    1. Pick an id and a starting point. List the bundled examples at the end of this guide. Scaffold from the closest one, or from a kind:

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

    6. Save. Gary reloads the plugin. Verify it as the next section describes.

    ### Write entry files

    - Each entry file is an ES module whose default export is an object with the fields in the Default export section.
    - Import other files of the plugin by relative path, such as `import { parse } from "./parse"`. Gary finds `parse.ts`, `parse.tsx`, `parse.js`, or an `index` file in a `parse` folder. The one other import is `gary:effect`, which the gary:effect section describes. Any other import, such as an npm package, fails the load with an error that names it. Each kind loads its own copy of an imported file, once.
    - Write services, timers, `fetch`, and `host.exec` work with Effect from `gary:effect`, and keep `render` synchronous.
    - Gary compiles TypeScript and modules with a bundled copy of sucrase and keeps line numbers. It erases type-only imports. It does not type-check, so run `tsc`.
    - There is no DOM, no `console`, and no Node.js API. Use `host.log` for logging, and `host.exec`, `host.readFile`, and `fetch` through their capabilities.
    - Keep module-level variables for state that survives renders. A reload starts the module again from the top, and `host.storage` keeps values across reloads and restarts.
    - Keep `render` pure and fast. Do slow work in timers or capability promises, store the result in a variable, and let the next render show it.
    - A promise from `host` resolves on the plugin's thread, and Gary renders again after the callback.

    ### Verify and debug

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

    static let reference = """
    ## manifest.json

    | Field | Type | Meaning |
    | --- | --- | --- |
    | `$schema` | string | Optional. `./manifest.schema.json` gives editors completion and checks. |
    | `schemaVersion` | `\(PluginManifest.schemaVersion)` | Required. |
    | `id` | string | Required. The plugin id, such as `you.weather`. |
    | `name`, `version` | string | Required. |
    | `kinds` | array | Required. One or more of \(PluginKind.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")). |
    | `entryPoints` | object | Required. One relative `.ts`, `.tsx`, or `.js` path per kind, such as `{ "panel": "panel.ts" }`. |
    | `subscribes` | array or object | Topics that appear in `state` and `onTopic`: capability topics, or other plugins' ids. An array gives every kind the same topics. An object gives each kind its own, such as `{ "menu": ["wifi"], "bar-widget": [] }`, so a topic runs only while a kind that reads it is loaded, and a kind it leaves out gets none. |
    | `uses` | array | Capabilities that add functions to `host`. |
    | `keepLoaded` | boolean | Keep a panel, overlay, or menu running while it is hidden. |
    | `mediakeys` | object | The media keys each kind takes over, such as `{ "overlay": ["volume-up", "volume-down", "mute"] }`. Keys are \(MediaKey.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")). While the plugin is enabled, macOS no longer acts on those keys. A press loads the kind if needed and calls its `onMediaKey`, so an overlay needs no service to catch keys. A bar widget takes its keys only while a bar section names it. Gary needs Accessibility. |
    | `surfaces` | object | The surface names of each panel, overlay, and menu, such as `{ "overlay": ["osd"] }`. A kind it leaves out has one surface, `main`. Two kinds cannot share a name. |
    | `bar` | string | `left`, `center`, or `right`, the default: the bar section that `gary plugin install`, `new`, and `enable` add a bar widget to. |
    | `hotkeys` | array | Global hotkeys, such as `{ "id": "open", "keys": "ctrl+alt+space" }`. Gary calls `onHotkey(id)`. A combination needs `cmd`, `ctrl`, or `alt`, unless its key is `f1` to `f12`. Modifiers are `cmd`, `ctrl`, `alt`, `shift`, and `hyper`, which is `ctrl+alt+cmd`. Keys are letters, digits, punctuation, `space`, `return`, `tab`, `delete`, `escape`, the arrows, and `f1` to `f12`. |

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

    `~/.config/gary/shell.json` turns plugins on and places bar widgets. `gary plugin` commands edit it, and Gary applies a saved change at once. Without the file, the bar shows the built-in `gary.battery` and `gary.clock` widgets on the right.

    | Field | Meaning |
    | --- | --- |
    | `bar` | `{ "left": [...], "center": [...], "right": [...], "notchLeft": [...] }`, lists of bar widget ids. On a display with a notch, `notchLeft` ends at the notch's left edge and `center` starts at its right edge, both `theme.bar.gap` away. Without a notch, `center` is centred and `notchLeft` ends just left of it. Naming a widget here enables it. Naming any section replaces the default sections. |
    | `bar.revealMenuBar` | `true` by default: when the pointer reaches the top edge of a display, the bar hides so macOS can reveal its menu bar, and returns when the menu bar hides again. `false` keeps the bar over the macOS menu bar. While a plugin hides the menu bar with the `menubar` capability, the bar stays. |
    | `plugins` | Ids of enabled plugins that are not bar widgets, such as panels and services. |
    | `disabledPlugins` | Ids to turn off, including built-in ones. |
    | `settings` | `{ "<id>": { ... } }`. Each plugin reads its object as `state.settings`. |
    | `packages` | Plugin packages that Gary installs and loads: `npm:<name>[@version\\|@tag]`, `git:<host>/<owner>/<repo>[@ref]`, a git URL, or an absolute or `~/` path to a folder that loads in place. `gary plugin install` and `gary plugin remove` edit it. |

    ## Default export

    | Field | Gary calls it |
    | --- | --- |
    | `render(state)` | After every change, once per display. It returns a node. A service needs no `render`. |
    | `onAction(action, payload, state)` | When the user clicks a node with `action`, right-clicks or middle-clicks a node with `rightAction` or `middleAction`, moves the pointer onto or off a node with `hoverAction`, moves a slider, or types in an input. |
    | `onKey(key, state)` | When a focused surface gets a key that no `input` takes. `key` names the key: \(Set(KeyName.named.values).sorted().map { "`\($0)`" }.joined(separator: ", ")), or else the typed character, such as `a`, `A`, or a space. `ctrl+`, `alt+`, `shift+`, and `cmd+` prefixes, in that order, give the held modifiers, such as `shift+tab` or `cmd+k`. `shift+` appears only before a named key, since a typed character already shows it. Return `true` when the plugin handled the key. Otherwise Gary handles it, so escape hides a menu or overlay. |
    | `onScroll(event, state)` | When the user scrolls with a mouse wheel or trackpad over a panel, overlay, or menu, or over a node with `scrollAction` in any kind. `event` has `x` and `y`, the distance in points, or in lines when `precise` is `false`, and `phase`: `began`, `changed`, and `ended` for a trackpad gesture, `momentum` for the glide after it, and `none` for a mouse wheel. Over a node with `scrollAction`, `event.action` holds that name. A `scroll` node under the pointer scrolls as well. |
    | `onHotkey(id, state)` | When a manifest hotkey fires. |
    | `onTopic({ topic, value }, state)` | When a subscribed topic changes, and once per topic at load. `value` has the type of `topic`, so `if (topic === "clock")` narrows it to a `Clock`. |
    | `onMediaKey(event, state)` | When a key that the manifest's `mediakeys` lists for this kind is pressed. Gary loads the kind first if it is not running. |
    | `methods` | `gary call <id> <method> [args...]` and `host.call` run one with string arguments. It returns a JSON value, or a promise of one. |
    | `effect` | Once after load, in the plugin's scope, when the module imports `gary:effect`. Unload and reload interrupt it. |
    | `surface` | An object, or a function of `state`, that places a panel, overlay, or menu. |
    | `surfaces` | An object that maps surface names to what `surface` takes, for a kind that shows several windows. Use it instead of `surface`. |

    ## state

    | Field | Value |
    | --- | --- |
    | `settings` | The plugin's object from `settings.<id>` in `shell.json`, or `{}`. |
    | `theme` | `{ mode, colors, palette }`, with colors as hex strings. |
    | `display` | The display being rendered: `{ id, index, main, width, height, notched, notch }`. Only in `render`. |
    | `surface` | The name of the surface being rendered, `main` for a module with only `surface` and for bar widgets and bars. Only in `render`. |
    | `<capability>` | The value of a subscribed capability topic. The capability sections below give its shape. |
    | `<plugin id>` | The last value that the plugin published, with the type from its `topic.ts`, or `Json` without one. |

    A topic field is `undefined` until its first value arrives, so check it before you use it. After that it always has the declared shape. A topic with `available: false` cannot read its data and gives the cause in `reason`, such as a missing permission. A nullable field is `null` when there is nothing to show. For example, `state.nowplaying.track` is `null` when nothing is playing.

    ## Open a panel from a bar widget

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

    ## host

    Every plugin has these functions. Capabilities add more.

    | Function | What it does |
    | --- | --- |
    | `host.log(message)` | Writes `plugin <id>: <message>` to Gary's log. |
    | `host.storage.get(key)`, `host.storage.set(key, value)` | Keeps JSON values in `~/Library/Application Support/Gary/storage/<id>.json`. Setting `undefined` deletes the key. |
    | `host.publish(value)` | Publishes a JSON value as the topic named by the plugin's id. When the plugin folder has a `topic.ts`, `value` must have its `Topic` type. |
    | `host.show(name?)`, `host.hide(name?)`, `host.toggle(name?)` | Shows or hides the plugin's surface named `name`, or `main`. A name that the manifest's `surfaces` does not list throws. A surface address, such as `you.music` or `you.music:osd`, names another plugin's surface, as in `gary summon`. When that plugin is not enabled or has no such surface, the call does nothing and Gary logs why. Called from `onAction`, or from `onScroll` over a node with `scrollAction`, `show` and `toggle` pass on the frame of the node the user clicked or scrolled, which a surface with `attach` opens at. Called later, such as after a promise or a timer, they pass on no frame. |
    | `host.call(method, ...args)`, `host.call({ plugin, kind }, method, ...args)` | Runs a function from the `methods` of one of the plugin's own kinds, or of another plugin's with `plugin`, such as `{ plugin: "you.recorder" }`, loading that kind if needed, and returns a promise of its result. With a target, such as `{ kind: "bar-widget" }`, it runs in that kind, so a panel can ask its bar widget. Without one, it runs in the first kind the plugin has in this order: \(PluginKind.handlerOrder.map { "`\($0.rawValue)`" }.joined(separator: ", ")). `gary call` and `onHotkey` go to that kind too. A bar widget that no bar section names is not running, so a call to it rejects. It rejects with the error the function threw or rejected with, or after 60 seconds. Another plugin must be enabled, or the call rejects. Plugins share data through `host.publish` and `subscribes`. |

    `setTimeout`, `setInterval`, `clearTimeout`, and `clearInterval` work as in a browser. An interval is at least 10 ms.

    ## gary:effect

    `gary:effect` gives a plugin [Effect](https://effect.website) \(PluginTypes.effectVersion). Only a plugin that imports it loads Effect, once per Gary process. Each importing plugin gets its own copy of the exports below, bound to that plugin's timers and its scope:

    | Export | What it is |
    | --- | --- |
    | `Effect`, `Stream`, `Schedule`, `Schema`, `Layer`, `Context`, `Scope`, `Fiber`, `Queue`, `PubSub`, `Ref`, `SubscriptionRef`, `Deferred`, `Semaphore`, `Cache`, `Option`, `Exit`, `Cause`, `Data`, `Duration`, `pipe` | Effect's modules. `Effect.runFork`, `Effect.runPromise`, and the other run functions start fibers on the plugin's timers and in its scope. |
    | `host` | The plugin's `host`, with each function returning an Effect. A function that throws or returns a rejected promise fails with a `HostError` that has a `message`. `host.spawn(argv)` returns a `Stream` of the command's stdout lines instead. It ends when the command exits with status 0, fails with a `HostError` that holds the status and the end of stderr otherwise, and stops the command when the stream is interrupted. |
    | `fetch` | `fetch` as an Effect, when the manifest uses `network`. |
    | `settings` | The plugin's `settings`. Changing them reloads the plugin. |
    | `topic(name)` | A `Stream` of a subscribed topic: its current value, then each change. |

    The default export's `effect` field is the plugin's long-running program, an `Effect<void, unknown, Scope>`. Gary runs it after load. On unload or reload, Gary closes the plugin's scope, which interrupts every fiber the plugin started and runs their finalizers. An effect that fails or dies fails the plugin. Handle expected errors, such as a `HostError`, inside the effect. Keep `render` synchronous: store results in module variables, and Gary renders after each timer and host callback.

    ```ts
    import { Effect, Schedule, host } from "gary:effect";

    let uptime = "…";

    const refresh = Effect.gen(function* () {
      const result = yield* host.exec(["/usr/bin/uptime"]);
      uptime = result.status === 0 ? result.stdout.trim() : "?";
    }).pipe(Effect.catchTag("HostError", (error) => host.log(error.message)));

    export default {
      effect: Effect.repeat(refresh, Schedule.spaced("1 minute")),
      render: () => ({ type: "text", text: uptime }),
    } satisfies Gary.BarWidget;
    ```

    A handler, such as `onAction`, `onKey`, `onScroll`, `onTopic`, or `onMediaKey`, can return an Effect, and Gary runs it at once in the plugin's scope. So `onAction() { return host.toggle(); }`, with `host` from `gary:effect`, opens the surface at the clicked node, and an `onKey` that returns an Effect has handled the key. An Effect that fails fails the plugin, as a thrown error does. A function in `methods` can return an Effect too: `host.call` and `gary call` get its result, or its error's message. An Effect that a handler neither returns nor runs does nothing, so `host.toggle();` on its own line is a mistake.

    For Effect style in general, follow the `effect` skill (kitlangton/skills) if it is installed. A plugin differs from the app that skill assumes:

    - Use `fetch`, `settings`, and `topic` from `gary:effect`, not `HttpClient`, `Config`, or environment variables.
    - Start long-running work in the `effect` field. Don't build a runtime, a `ManagedRuntime`, or Layers for it.
    - Never use Effect's microtask scheduler. Its work runs inside one call and trips the 100 ms limit.

    `gary plugin types` adds these declarations to `gary.d.ts` when a file of the plugin imports `gary:effect`. They import from the `effect` package, so run `npm install --save-dev effect@\(PluginTypes.effectVersion)` in the plugin folder. The `tsconfig.json` that `gary plugin types` writes sets `"skipLibCheck": true`, because Effect's own declarations name browser types that Gary does not have.

    ```ts
    \(PluginTypes.effectDeclarations.trimmingCharacters(in: .newlines))
    ```

    ## Nodes

    `render` returns a node: a plain object with a `type`. In a `.tsx` file, JSX builds the same objects. A lowercase tag is a node type and its attributes are the node's fields. Child tags become `children`, and the text inside `<text>` becomes `text`. `false`, `null`, and `undefined` children drop out, and arrays flatten, so `{items.map(...)}` and `{done && <icon symbol="checkmark" />}` work. `<>...</>` groups children inside a node but is not a node itself. A capitalized tag calls a function of your own with the attributes as one object, and the child tags in `children`:

    ```tsx
    function Stat({ symbol, value }: { symbol: string; value: string }) {
      return (
        <row gap={4}>
          <icon symbol={symbol} style="dim" />
          <text>{value}</text>
        </row>
      );
    }

    export default {
      render: () => <Stat symbol="cpu" value={load} />,
    } satisfies Gary.BarWidget;
    ```

    `gary.d.ts` types each tag with the fields of its node and `tsconfig.json` sets `"jsx": "react"` with `Gary.h` as the factory, which `gary plugin new` and `gary plugin types` write for you. Every node takes `key`, `style`, \(Node.Gesture.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")), `tooltip`, and the style properties \(StyleProps.names.map { "`\($0)`" }.joined(separator: ", ")). Numbers are points, except `opacity` from 0 to 1. A number outside its range, such as a negative `width` or an `opacity` above 1, counts as the nearest end of the range. A property on the node overrides the same property in its `style`.

    | `type` | Own fields | `onAction` payload |
    | --- | --- | --- |
    | `row`, `column` | `children` | `null` |
    | `stack` | `children`, drawn on top of each other from the top left corner, later children above earlier ones unless `zIndex` says otherwise. Give the stack a `width` and `height`, and place each child with `x` and `y`. | `null` |
    | `scroll` | `children`, and `reveal`, the key of a child to keep in view | `null` |
    | `button` | `children`, and `hover`, a style name for the pointer-over state | `null` |
    | `text` | `text`, a string or number | `null` |
    | `icon` | `symbol`, an SF Symbol name such as `battery.75percent` | `null` |
    | `image` | `path` to an image file, absolute, from `~`, or relative to the plugin folder, and `fit` | `null` |
    | `slider` | `value` from 0 to 1, `rate` and `at`, and `release`, an action sent once when the user lets go | the new value, to `action` while the user drags and to `release` when they let go |
    | `progress` | `value` from 0 to 1, `rate` and `at` | `null` |
    | `input` | `value`, `placeholder`, `change`, and `submit` | the text. `change` and `submit` name the actions. |
    | `spacer` | none. It fills the free space in a row or column, and a row with a spacer spans the width of its column, so the items after the spacer line up at the trailing edge. | `null` |
    | `shape` | `viewBox` and `paths`, SVG paths to fill and stroke. The Drawing section covers it. | `null` |
    | `chart` | `series`, `min`, `max`, `axes`, and `labels`. The Drawing section covers it. | `null` |
    | `grid` | `children` and `columns`, the number of cells in each row | `null` |
    | `shader` | `path`, `function`, `args`, and `animated`, a Metal function that draws the node. The Drawing section covers it. | `null` |

    - `rate` moves a `slider` or `progress` on its own by that fraction per second, from `value` at `at`, a time in milliseconds since 1970 such as `Date.now()` or a track's `elapsedAt`, or from when Gary first shows it. It stops at 0 or 1. After a drag, a slider moves on from where the user let go until `render` returns a different value. A seek bar for a `nowplaying` track needs no timer: `{ value: track.elapsed / track.duration, rate: track.playing ? track.rate / track.duration : 0, at: track.elapsedAt }`.
    - `width` and `height` give a node exactly that size, padding included, and `minWidth` keeps it at least that wide. A `scroll` grows with its content up to its `height`.
    - `padding` is one number for every side, `[vertical, horizontal]`, or `[top, right, bottom, left]`.
    - `align` places the content of a node that is wider than its content, such as text with a `width`: `"leading"`, `"center"`, or `"trailing"`. It also aligns the lines of wrapped text. A node aligns to `"leading"`, and an icon to `"center"`.
    - `x` and `y` move a node right and down from where its container places it, or left and up when negative, without moving its siblings. In a `stack` they place the child from the top left corner.
    - `zIndex` draws a node above its siblings with a lower `zIndex`. It is `0` by default.
    - `scale` draws a node larger or smaller around its center, such as `0.97`, without changing its layout size.
    - `animation` animates what changes inside the node when `render` returns a different tree: `"smooth"`, `"spring"`, or `"none"`, which turns off an animation that an enclosing node set. `duration` sets its length in seconds. Sizes, positions, `x`, `y`, `scale`, `opacity`, colors, shadows, and progress values move, and changed text cross-fades. Keyed children keep their identity, so a child whose `x` or `width` changes slides and resizes. Gary draws no animation when the user turns on Reduce Motion.
    - `transition` says how a child appears and disappears when a render adds or removes it: `"opacity"`, the default, fades it, `"scale"` grows or shrinks it from its center, and `"none"` shows and hides it at once. An enclosing `animation` sets the timing.
    - `radius` rounds the corners with Apple's continuous curve. `clip: true` cuts the node's content to that rounded shape.
    - `border` draws a line inside the edge: `{ color, width }`, with `width` 1 by default.
    - `shadow` draws a shadow under the node: `{ color, radius, y }`. Use a translucent color, such as `alpha(#000000, 0.45)`.
    - `hovered` and `pressed` are objects of style properties that apply while the pointer is over the node, and while the user holds the mouse button down on a node with `action`. They fade in and out over 0.15 seconds, so `{ opacity: 0.2 }` brightens a dimmed overlay and `{ scale: 0.97 }` presses a card in.
    - `fit` sets how an `image` fills its `width` and `height`: `"fit"`, the default, shows the whole image, and `"fill"` covers the box and cuts off what overflows. Gary decodes the file at the size the screen shows it and caches it. A file of 32 KB or less, such as an icon, shows in the first frame. A larger file decodes off the main thread and appears when it is ready, at once, or through its `transition` timed by its own `animation` and `duration`.
    - `material` paints a material behind the node, inside its `radius` and under its `background`: `"vibrant"` blurs what is behind the window, `"glass"` is Liquid Glass, and `"none"` removes a material that the node's `style` sets. Give `background` a translucent color, such as `alpha(panel, 0.4)`, to tint it.
    - `colorScheme` draws the node and everything inside it in `"dark"` or `"light"` appearance, whatever the theme's mode, so a `material` and system colors follow it. White text on a `"vibrant"` caption stays readable in a light theme with `colorScheme: "dark"`.
    - A `text` node is exactly as wide as its text and as tall as its lines, with no padding of its own. `lines` caps the lines it wraps to, and `truncate` says where text that does not fit is cut with "…": `"tail"`, the default, `"middle"`, or `"head"`. Text in a bar widget or bar keeps to one line unless it sets `lines`. A `text` node with its own `width` keeps to one line and spills over the edge, unless it sets `truncate`, or `lines` to wrap within the width. To wrap text at a width, give the width to its row or column.
    - A `row` gives each child its own width when it has room and hands the spare width to its spacers. A row narrower than its children shortens the widest first, so a long title truncates before a short label next to it.
    - Give siblings unique `key` values so Gary keeps each child's view, and its state such as hover or typed text, when the order changes.
    - A node with `action` is clickable. Gary calls `onAction(action, payload)`.
    - `rightAction` and `middleAction` name the action for a right click and a middle click on the node, with a `null` payload. `scrollAction` sends a scroll over the node to `onScroll`, with the name in the event's `action`. `hoverAction` sends the name to `onAction` with `true` when the pointer moves onto the node and `false` when it leaves, so a list can move its selection to the row under the pointer. A `scroll` node with `scrollAction` still scrolls its children. When nested nodes name an action for the same gesture, the innermost node under the pointer takes it. These work in bar widgets, bars, panels, overlays, and menus.
    - `tooltip` is text that Gary shows below the node after the pointer rests on it for half a second, or above the node when there is no room below. It hides when the pointer leaves, on any click, and when the node goes away. The theme's `tooltip` style paints it.
    - An `image` path that does not start with `/` or `~` is relative to the plugin folder, so a plugin can ship its own images. A path that ends in `.app` shows that app's icon. An `image` with its own `color` draws as a template: its shape filled with that color, so a black menu bar icon shows in `foreground`.
    - Text wraps when its surface is narrower than the text, such as a surface with a fixed `width` or one at the display's edge. Text in a `button` stays on one line.
    - A tree holds at most 1000 nodes and 16 levels.
    - Colors are \(ColorExpr.syntax).

    ## surface

    These fields place a surface, whether it comes from `surface` or from an entry in `surfaces`.

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
    | `attach` | boolean. When `host.show()` or `host.toggle()` runs in `onAction`, the surface opens centred below the node the user clicked, `margins.top` points away, or above it when there is no room below. A node in the bar measures from the bar's bottom edge, so every bar widget's surface opens the same distance below the bar. The surface stays `theme.spacing.edge` points inside the display. `gary action` clicks the node the same way. Shown without a click, such as by `gary summon`, a hotkey, or a timer, it uses `anchors` and `margins`. | `false` |
    | `background` | `"solid"` paints the theme's `surface` style, including its `material`, with a border and a shadow. `"none"` leaves the window clear for the tree to paint, so a root node with `material` and `radius` gives one surface its own material. `"backdrop"` leaves the window clear too, centres the root node in it, catches every click, and hides the surface when a click lands where no node paints or takes the click. With `anchors` on every edge and `exclusionMode` `"ignore"`, it gives a full-display picker: `{ anchors: { top: true, bottom: true, left: true, right: true }, exclusionMode: "ignore", background: "backdrop" }`. | `"solid"` |
    """
}
