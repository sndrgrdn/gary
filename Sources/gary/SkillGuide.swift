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
            "## Core type declarations\n\n`gary plugin types` writes these into `gary.d.ts`, followed by the declarations of each capability the manifest names.\n\n```ts\n\(PluginTypes.declarations(capabilities: [], pluginTopics: [], theme: theme).trimmingCharacters(in: .newlines))\n```",
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

    static let developLoop = """
    ## Build a plugin

    1. Pick an id and a starting point. List the bundled examples at the end of this guide. Scaffold from the closest one, or from a kind:

    	```sh
    	gary plugin new you.weather --from load
    	gary plugin new you.launcher --kind menu
    	gary plugin new you.music --kind bar-widget,panel
    	```

    	Gary writes `~/.config/gary/plugins/<id>/` with `manifest.json`, one entry file per kind, `gary.d.ts`, `manifest.schema.json`, `tsconfig.json`, and `README.md`. It turns the plugin on in `~/.config/gary/shell.json`, and a bar widget goes to the bar section that the manifest's `bar` field names, `right` by default. Gary reloads the plugin each time you save a file in that folder. `--dir <folder>` scaffolds elsewhere and records the folder in `packages` in `shell.json`, so Gary loads it in place.
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
    - `gary call <id> <method> [args...]` runs a function from the module's `methods`, loading the plugin first if needed. When the function returns a promise, it waits up to 60 seconds for it. It prints a string result as is and anything else as JSON. A thrown error or rejected promise prints its message and exits with status 1. Add a `methods` entry that returns internal state when you need to inspect it.
    - `gary summon <id>`, `gary hide <id>`, and `gary toggle <id>` show and hide a panel, overlay, or menu, as `host.show()`, `host.hide()`, and `host.toggle()` do.
    - `gary action <id> <kind> <action> [payload]` sends `onAction` to a running kind, as a click on a node with that `action` would, and Gary renders again. Pass a number for a slider value or text for an input. Use it to test clicks instead of synthesizing mouse events, which need Accessibility for your terminal. For example, `gary action you.music bar-widget toggle` runs the widget's click handler, and `gary listPlugins` then shows `panel:shown`.
    - `gary reloadPlugins <id>` reloads a plugin from disk. `gary rescanPlugins` finds added and removed plugin folders.
    - `gary doctor` reports private API, permission, plugin, `shell.json`, and theme problems.
    - `gary permissions` shows which macOS permissions Gary has and which enabled plugins need them. A capability that lacks a permission says so in its error or topic value, with the `gary permissions request <name>` command that asks for it.
    - Take a screenshot to check the result. Capture only the rectangle you need with `-R x,y,width,height`, because a full-screen capture includes the user's other windows. `screencapture -x -R 0,0,1728,40 /tmp/bar.png` captures the bar of a display 1728 points wide. The `screens` line in the log gives each display's size in points. Rectangles are in points from the top left of the main display. A Retina PNG has two pixels per point, so halve PNG pixel positions to get points. The bar is `theme.bar.height` points tall, 32 by default. Summon a surface before you capture it, and capture the corner its `anchors` and `margins` place it in. The screenshot needs Screen Recording for the program that runs `screencapture`, not for Gary.
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
    | `entryPoints` | object | Required. One relative `.ts` or `.js` path per kind, such as `{ "panel": "panel.ts" }`. Symlinks are refused. |
    | `subscribes` | array | Topics that appear in `state` and `onTopic`: capability topics, or other plugins' ids. |
    | `uses` | array | Capabilities that add functions to `host`. |
    | `keepLoaded` | boolean | Keep a panel, overlay, or menu running while it is hidden. |
    | `bar` | string | `left`, `center`, or `right`, the default: the bar section that `gary plugin install`, `new`, and `enable` add a bar widget to. |
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

    `~/.config/gary/shell.json` turns plugins on and places bar widgets. `gary plugin` commands edit it, and Gary applies a saved change at once. Without the file, the bar shows the built-in `gary.battery` and `gary.clock` widgets on the right.

    | Field | Meaning |
    | --- | --- |
    | `bar` | `{ "left": [...], "center": [...], "right": [...] }`, lists of bar widget ids. Naming a widget here enables it. Naming any section replaces the default sections. |
    | `bar.revealMenuBar` | `true` by default: when the pointer reaches the top edge of a display, the bar hides so macOS can reveal its menu bar, and returns when the menu bar hides again. `false` keeps the bar over the macOS menu bar. While a plugin hides the menu bar with the `menubar` capability, the bar stays. |
    | `plugins` | Ids of enabled plugins that are not bar widgets, such as panels and services. |
    | `disabledPlugins` | Ids to turn off, including built-in ones. |
    | `settings` | `{ "<id>": { ... } }`. Each plugin reads its object as `state.settings`. |
    | `packages` | Plugin packages that Gary installs and loads: `npm:<name>[@version\\|@tag]`, `git:<host>/<owner>/<repo>[@ref]`, a git URL, or an absolute or `~/` path to a folder that loads in place. An entry is a string or `{ "source": "..." }`. `gary plugin install` and `gary plugin remove` edit it. |

    ## Module exports

    | Export | Gary calls it |
    | --- | --- |
    | `render(state)` | After every change, once per display. It returns a node. A service needs no `render`. |
    | `onAction(action, payload, state)` | When the user clicks a node with `action`, right-clicks, middle-clicks, or scrolls a node with `rightAction`, `middleAction`, or `scrollAction`, moves a slider, or types in an input. |
    | `onKey(key, state)` | When a focused surface gets a key that no `input` takes. `key` names the key: \(Set(KeyName.named.values).sorted().map { "`\($0)`" }.joined(separator: ", ")), or else the typed character, such as `a`, `A`, or a space. `ctrl+`, `alt+`, `shift+`, and `cmd+` prefixes, in that order, give the held modifiers, such as `shift+tab` or `cmd+k`. `shift+` appears only before a named key, since a typed character already shows it. Return `true` when the plugin handled the key. Otherwise Gary handles it, so escape hides a menu or overlay. |
    | `onScroll(event, state)` | When the user scrolls with a mouse wheel or trackpad over a panel, overlay, or menu, except over a node with `scrollAction`. `event` has `x` and `y`, the distance in points, or in lines when `precise` is `false`, and `phase`: `began`, `changed`, and `ended` for a trackpad gesture, `momentum` for the glide after it, and `none` for a mouse wheel. A `scroll` node under the pointer scrolls as well. |
    | `onHotkey(id, state)` | When a manifest hotkey fires. |
    | `onTopic(topic, value, state)` | When a subscribed topic changes, and once per topic at load. |
    | `onMediaKey(event, state)` | When a key that `host.mediakeys.intercept` claimed is pressed. |
    | `methods` | `gary call <id> <method> [args...]` and `host.call(method, ...args)` run one with string arguments. It returns a JSON value, or a promise of one. |
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
    | `host.show()`, `host.hide()`, `host.toggle()` | Shows or hides the plugin's surface. Called from `onAction`, `show` and `toggle` pass on the frame of the node the user clicked, which a surface with `attach` opens at. Called later, such as after a promise or a timer, they pass on no frame. |
    | `host.call(method, ...args)` | Runs a function from the plugin's own `methods`, in the kind that `gary call` would run, loading it if needed, and returns a promise of its result. It rejects with the error the function threw or rejected with, or after 60 seconds. Plugins reach each other only through `host.publish` and `subscribes`. |

    `setTimeout`, `setInterval`, `clearTimeout`, and `clearInterval` work as in a browser. An interval is at least 10 ms.

    ## Nodes

    `render` returns a node: a plain object with a `type`. Every node takes `key`, `style`, \(Node.Gesture.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")), `tooltip`, and the style properties \(StyleProps.names.map { "`\($0)`" }.joined(separator: ", ")). Numbers are points, except `opacity` from 0 to 1. A property on the node overrides the same property in its `style`.

    | `type` | Own fields | `onAction` payload |
    | --- | --- | --- |
    | `row`, `column` | `children` | `null` |
    | `stack` | `children`, drawn on top of each other from the top left corner, later children above earlier ones unless `zIndex` says otherwise. Give the stack a `width` and `height`, and place each child with `x` and `y`. | `null` |
    | `scroll` | `children`, and `reveal`, the key of a child to keep in view | `null` |
    | `button` | `children`, and `hover`, a style name for the pointer-over state | `null` |
    | `text` | `text`, a string or number | `null` |
    | `icon` | `symbol`, an SF Symbol name such as `battery.75percent` | `null` |
    | `image` | `path` to an image file, absolute, from `~`, or relative to the plugin folder, and `fit` | `null` |
    | `slider` | `value` from 0 to 1 | the new value |
    | `progress` | `value` from 0 to 1 | `null` |
    | `input` | `value`, `placeholder`, `change`, and `submit` | the text. `change` and `submit` name the actions. |
    | `spacer` | none. It fills the free space in a row or column, and a row with a spacer spans the width of its column, so the items after the spacer line up at the trailing edge. | `null` |
    | `shape` | `viewBox` and `paths`, SVG paths to fill and stroke. The Drawing section covers it. | `null` |
    | `chart` | `series`, `min`, `max`, and `axes`. The Drawing section covers it. | `null` |
    | `grid` | `children` and `columns`, the number of cells in each row | `null` |
    | `shader` | `path`, `function`, `args`, and `animated`, a Metal function that draws the node. The Drawing section covers it. | `null` |

    - `width` and `height` give a node exactly that size, padding included, and `minWidth` keeps it at least that wide. A `scroll` grows with its content up to its `height`.
    - `padding` is one number for every side, `[vertical, horizontal]`, or `[top, right, bottom, left]`.
    - `align` places the content of a node that is wider than its content, such as text with a `width`: `"leading"`, `"center"`, or `"trailing"`. It also aligns the lines of wrapped text. A node aligns to `"leading"`, and an icon to `"center"`.
    - `x` and `y` move a node right and down from where its container places it, or left and up when negative, without moving its siblings. In a `stack` they place the child from the top left corner. `offset` is an older name for `y` and adds to it.
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
    - A `text` node is exactly as wide as its text and as tall as its lines, with no padding of its own. A `text` node with its own `width` keeps its text on one line, placed by `align`, and text wider than that spills over the edge. To wrap text at a width, give the width to its row or column.
    - Give siblings unique `key` values so Gary keeps each child's view, and its state such as hover or typed text, when the order changes.
    - A node with `action` is clickable. Gary calls `onAction(action, payload)`.
    - `rightAction` and `middleAction` name the action for a right click and a middle click on the node, with a `null` payload. `scrollAction` names the action for a scroll over the node, and its payload is the event that `onScroll` gets. A scroll that a node takes does not reach `onScroll`. A `scroll` node with `scrollAction` still scrolls its children. When nested nodes name an action for the same gesture, the innermost node under the pointer takes it. These work in bar widgets, bars, panels, overlays, and menus.
    - `tooltip` is text that Gary shows below the node after the pointer rests on it for half a second, or above the node when there is no room below. It hides when the pointer leaves, on any click, and when the node goes away. The theme's `tooltip` style paints it.
    - An `image` path that does not start with `/` or `~` is relative to the plugin folder and must stay inside it, so a plugin can ship its own images. A path that ends in `.app` shows that app's icon.
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
    | `attach` | boolean. When `host.show()` or `host.toggle()` runs in `onAction`, the surface opens centred below the node the user clicked, `margins.top` points away, or above it when there is no room below, and stays `theme.spacing.edge` points inside the display. Shown without a click, such as by `gary summon`, a hotkey, or a timer, it uses `anchors` and `margins`. | `false` |
    | `background` | `"solid"` paints the theme's `surface` style, including its `material`, with a border and a shadow. `"none"` leaves the window clear for the tree to paint, so a root node with `material` and `radius` gives one surface its own material. `"backdrop"` leaves the window clear too, centres the root node in it, catches every click, and hides the surface when a click lands where no node paints or takes the click. With `anchors` on every edge and `exclusionMode` `"ignore"`, it gives a full-display picker: `{ anchors: { top: true, bottom: true, left: true, right: true }, exclusionMode: "ignore", background: "backdrop" }`. | `"solid"` |
    """
}
