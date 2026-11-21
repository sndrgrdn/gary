# Writing Gary plugins

A plugin is a folder with a `manifest.json` and one entry file per kind. Gary runs each entry file in its own JavaScriptCore context. It calls `render(state)` and draws the node tree that `render` returns. Entry files are TypeScript (`.ts`) or JavaScript (`.js`).

Gary.app bundles the plugins in [`examples/`](../examples) in `Contents/Resources/examples`. Gary does not load them. Copy one under your own id to start:

| Example | Shows |
| --- | --- |
| [`load`](../examples/load) | A bar widget that runs a command with `host.exec`. |
| [`disk`](../examples/disk) | A service that publishes a value and a bar widget that subscribes to it. |
| [`timer`](../examples/timer) | A panel with buttons, a slider, a progress bar, and `host.storage`. |
| [`today`](../examples/today) | A panel that subscribes to the `clock` and `battery` topics. |

The only built-in plugins are the `gary.clock` and `gary.battery` bar widgets, so a fresh install shows a bar.

## Create a plugin

1. Scaffold a bar widget and turn it on:

	```sh
	gary plugin new you.hello --enable
	```

	Gary writes `~/.config/gary/plugins/you.hello/` with `manifest.json`, `widget.ts`, `gary.d.ts`, `manifest.schema.json`, `tsconfig.json`, and `README.md`. The widget appears at the right of the bar. To start from an example instead, pass `--from`, such as `gary plugin new you.timer --from timer --enable`. Gary replaces the example's id with yours in every file.
2. Edit `widget.ts` and save. Gary reloads the plugin within about 40 ms. If the new version fails, Gary logs the reason and keeps the running version.
3. Type-check the folder:

	```sh
	npx -p typescript tsc -p ~/.config/gary/plugins/you.hello
	```

4. Run the checks Gary runs when it loads plugins:

	```sh
	gary plugin validate ~/.config/gary/plugins/you.hello
	```

For another kind, pass `--kind`, for example `--kind panel` or `--kind service,bar-widget`. To scaffold outside the plugins folder, pass `--dir <path>`.

Gary logs `host.log` lines and load failures. The app writes them to `~/Library/Logs/gary.log`. Run `gary app` in a terminal to see them live.

## Write TypeScript

Gary strips types with a bundled copy of [sucrase](https://github.com/alangpierce/sucrase) and keeps line numbers, so errors point at the `.ts` line. Gary does not type-check. Run `tsc` for that.

- Assign `module.exports`. Gary runs each file as a plain script, so `import` and `export` are syntax errors.
- Add `satisfies Gary.BarWidget`, `Gary.Panel`, `Gary.Service`, or the type for your kind. TypeScript then types `state` and checks the tree you return.
- After you change `uses` or `subscribes`, run `gary plugin types <folder>`. `gary.d.ts` declares only the `host` functions and `state` fields that your manifest asks for.

## Share a plugin

Put the plugin folder at the root of a git repository and push it. Others install it with:

```sh
gary plugin add https://github.com/you/gary-hello.git --enable
```

`gary plugin add` also takes a local repository path, a `file://` URL, or a plain folder, which it copies. It clones into a staging folder and validates the plugin. It refuses an id that is already installed and any `gary.` id. It then prints a warning that plugins run unsandboxed, lists the capabilities in `uses` with their macOS permissions, and moves the folder to `~/.config/gary/plugins/<id>`. It never runs plugin code.

| Command | What it does |
| --- | --- |
| `gary plugin list` | Lists installed plugins, whether `shell.json` enables them, and where they came from. |
| `gary plugin enable <id>`, `gary plugin disable <id>` | Edits `~/.config/gary/shell.json`. A bar widget goes to the right of the bar. |
| `gary plugin update <id> [--yes]` | Fetches, shows the log and the diff, validates the new revision, and fast-forwards. It refuses local changes. Without a terminal it needs `--yes`. |
| `gary plugin remove <id>` | Moves the folder to the Trash and drops the id from `shell.json`. Settings stay. |
| `gary plugin types [folder]` | Writes `gary.d.ts` and `manifest.schema.json`. |

## Reference

### manifest.json

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | `1` | Required. |
| `id` | string | Required. Two or more dot-separated segments of lowercase letters, digits, and hyphens, such as `you.hello`. The `gary.` namespace is reserved. |
| `name`, `version` | string | Required. |
| `kinds` | array | Required. One or more of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, and `service`. |
| `entryPoints` | object | Required. One relative `.ts` or `.js` path per kind, such as `{ "panel": "panel.ts" }`. Symlinks are refused. |
| `subscribes` | array | Topics whose values appear in `state`: a capability topic such as `clock`, `battery`, `audio`, or `wifi`, or another plugin's id. A capability topic runs only while some plugin subscribes to it. |
| `uses` | array | Capabilities that add functions to `host`, such as `exec`, `files`, `network`, `clipboard`, or `audio`. `manifest.schema.json` lists them all. |
| `keepLoaded` | boolean | Keep a panel, overlay, or menu running while it is hidden. |
| `hotkeys` | array | `{ "id": "open", "keys": "ctrl+alt+space" }`. Gary calls `onHotkey(id)`. A combination needs `cmd`, `ctrl`, or `alt`, unless its key is `f1` to `f12`. |

### Kinds

| Kind | Runs as |
| --- | --- |
| `bar-widget` | A view in the bar. Place it with `bar.left`, `bar.center`, or `bar.right` in `shell.json`. |
| `bar` | A whole bar that replaces the built-in one. |
| `panel`, `overlay`, `menu` | A window you show with `gary summon <id>`, `gary toggle <id>`, or `host.show()`. A menu takes keys and hides when you click outside it. |
| `service` | A script with no view. It publishes values and answers `gary call`. |

### Module exports

| Export | Called |
| --- | --- |
| `render(state)` | After every change to `state`, once per display. Returns a node. A service needs no `render`. |
| `onAction(action, payload, state)` | When someone clicks a node with `action`, moves a slider, or types in an input. |
| `onKey(key, state)` | When a focused surface gets `up`, `down`, `enter`, `escape`, or `tab`. |
| `onHotkey(id, state)` | When a manifest hotkey fires. |
| `onTopic(topic, value, state)` | When a subscribed topic gets a new value, and once per topic at load. |
| `onMediaKey(event, state)` | When a key that `host.mediakeys.intercept` claimed is pressed. |
| `methods` | Functions that `gary call <id> <method> [args...]` runs with string arguments. A string result prints as is, and anything else prints as JSON. |
| `surface` | An object, or a function of `state`, that places a panel, overlay, or menu. |

Gary renders again after every handler, timer, and host callback. It draws only when the tree changed. A call that runs longer than 100 ms is stopped, and the plugin fails.

### State

| Field | Value |
| --- | --- |
| `settings` | The plugin's object from `settings.<id>` in `shell.json`. |
| `theme` | `{ mode, colors, palette }`, with colors as hex strings. |
| `display` | `{ id, index, main, width, height, notched, notch }`. Only in `render`. |
| `clock` | `{ epoch }`, updated each minute. Needs `subscribes: ["clock"]`. |
| `battery` | `{ present, percent, charging, source }`. Needs `subscribes: ["battery"]`. |
| `<plugin id>` | The last value that plugin published. Needs its id in `subscribes`. |
| `<capability>` | The value of any other subscribed capability topic. `gary.d.ts` gives its shape. |

### host

| Function | Needs | Does |
| --- | --- | --- |
| `host.log(message)` | | Writes to Gary's log. |
| `host.storage.get(key)`, `host.storage.set(key, value)` | | Keeps JSON values in `~/Library/Application Support/Gary/storage/<id>.json`. |
| `host.publish(value)` | | Publishes a JSON value under the plugin's id. |
| `host.show()`, `host.hide()`, `host.toggle()` | | Shows or hides the plugin's surface. |
| `host.exec(argv, callback)` | `exec` | Runs a command off the main thread and calls back with `{ status, stdout, stderr }`. |
| `host.readFile(path)`, `writeFile(path, text)`, `mkdir(path)`, `remove(path)`, `list(path)`, `watchFile(path, callback)` | `files` | Reads, writes, and lists files, or calls back with a file's text after each change. A path is absolute or starts with `~/`. |
| `fetch(url)` | `network` | Resolves to `{ status, text }` for an `http` or `https` URL. |
| `host.<capability>.<method>(...)` | the capability | The other capabilities, such as `host.clipboard.read()` or `host.audio.setVolume(0.5)`. `gary.d.ts` lists every method. |

`setTimeout`, `setInterval`, `clearTimeout`, and `clearInterval` work as in a browser. There is no `console`. Use `host.log`.

### Nodes

Every node takes `key`, `style`, `action`, `width`, `height`, `padding`, `gap`, `radius`, `fontSize`, `opacity`, `background`, `color`, and `font`. `style` names a style from the theme, such as `default`, `active`, `dim`, `title`, `panel`, `hover`, or `selected`. Colors are theme color names, `#rrggbb`, or `mix(a, b, t)`, `alpha(c, a)`, and `contrast(c)`.

| `type` | Own fields | `onAction` payload |
| --- | --- | --- |
| `row`, `column` | `children` | `null` |
| `scroll` | `children`, `reveal` (a child key to keep in view) | |
| `button` | `children`, `hover` (a style name) | `null` |
| `text` | `text` | `null` |
| `icon` | `symbol` (an SF Symbol name) | `null` |
| `image` | `path` | `null` |
| `slider` | `value` from 0 to 1 | the new value |
| `progress` | `value` from 0 to 1 | `null` |
| `input` | `value`, `placeholder`, `change`, `submit` | the text, sent as the `change` or `submit` action |
| `spacer` | | `null` |

Give siblings unique `key` values so Gary can patch the views in place. A tree holds at most 1000 nodes and 16 levels.

### surface

| Field | Values | Default |
| --- | --- | --- |
| `screen` | `"main"`, `"focused"`, `"all"`, or a display index | `"focused"` |
| `anchors` | `{ top, bottom, left, right }` booleans | none, so centered. An overlay anchors to every edge. |
| `width`, `height` | points or `"fit"` | `"fit"` |
| `margins` | points, or `{ top, bottom, left, right }` | `0` |
| `layer` | `desktop`, `below`, `normal`, `top`, `overlay`, or `notch` | `top`. An overlay or menu uses `overlay`. |
| `exclusionMode` | `"normal"` keeps clear of the bar, and `"ignore"` covers it | `"normal"`. An overlay uses `"ignore"`. |
| `clickThrough`, `focusable` | booleans | `false`. A menu is focusable. |
