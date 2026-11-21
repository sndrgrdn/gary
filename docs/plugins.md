# Writing Gary plugins

A plugin is a folder with a `manifest.json` and one entry file per kind. Gary runs each entry file in its own JavaScriptCore context. It calls `render(state)` and draws the node tree that `render` returns. Entry files are TypeScript (`.ts`) or JavaScript (`.js`).

Gary.app bundles the plugins in [`examples/`](../examples) in `Contents/Resources/examples`. Gary does not load them. Copy one under your own id to start:

| Example                      | Shows                                                                    |
| ---------------------------- | ------------------------------------------------------------------------ |
| [`load`](../examples/load)   | A bar widget that runs a command with `host.exec`.                       |
| [`disk`](../examples/disk)   | A service that publishes a value and a bar widget that subscribes to it. |
| [`timer`](../examples/timer) | A panel with buttons, a slider, a progress bar, and `host.storage`.      |
| [`today`](../examples/today) | A panel that subscribes to the `clock` and `battery` topics.             |

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

## Lay out nodes

Gary draws each node tree with SwiftUI. A `row` is a horizontal stack, a `column` is a vertical stack, a `stack` layers its children from its top left corner, and a `spacer` takes the free space. Every node takes these style properties, as does every style in `theme.json`:

| Property                   | Value                                                                                                                                                                                                                    |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `padding`                  | One number for every side, `[vertical, horizontal]`, or `[top, right, bottom, left]`.                                                                                                                                    |
| `width`, `height`          | The exact size in points, padding included.                                                                                                                                                                              |
| `minWidth`                 | The smallest width in points.                                                                                                                                                                                            |
| `align`                    | `"leading"`, `"center"`, or `"trailing"`: where the content sits in a node wider than its content, and how wrapped lines align.                                                                                          |
| `x`, `y`                   | Points to move the node right and down, or left and up when negative, without moving its siblings. In a `stack` they place the child. `offset` is an older name for `y`.                                                 |
| `zIndex`                   | Draws the node above siblings with a lower `zIndex`.                                                                                                                                                                     |
| `scale`                    | Draws the node larger or smaller around its center without changing its layout size.                                                                                                                                     |
| `animation`                | `"smooth"`, `"spring"`, or `"none"`: how the node animates what changes inside it between renders. `duration` sets its length in seconds. Reduce Motion turns it off.                                                    |
| `transition`               | `"opacity"`, `"scale"`, or `"none"`: how a child appears and disappears.                                                                                                                                                 |
| `material`                 | `"vibrant"`, `"glass"`, or `"none"`: a material behind the node, inside its `radius`.                                                                                                                                    |
| `colorScheme`              | `"dark"` or `"light"`: the appearance of the node and its children, whatever the theme's mode. A `material` and system colors follow it.                                                                                 |
| `clip`, `border`, `shadow` | `clip: true` cuts the content to the rounded `radius`. `border` is `{ color, width }` and `shadow` is `{ color, radius, y }`.                                                                                            |
| `fit`                      | `"fit"` or `"fill"`: how an `image` fills its size. Gary decodes images at the size they show, a file over 32 KB off the main thread. It appears when ready, faded only by the image's own `transition` and `animation`. |

A node also takes `hovered` and `pressed`: objects of style properties that apply while the pointer is over it, and while a node with `action` is held down.

A `text` node is exactly as wide as its text, with no padding of its own. This row centers each workspace number in a 20-point cell and moves it down 1 point:

```ts
{
	type: "row",
	gap: 1,
	children: [1, 2, 3].map((n): Gary.Node => ({ type: "text", key: String(n), text: n, width: 20, align: "center", offset: 1 })),
}
```

To give every panel, overlay, and menu a material, set it on the `surface` style in `~/.config/gary/theme.json`, with a translucent background:

```json
{ "styles": { "surface": { "material": "glass", "background": "alpha(panel, 0.4)" } } }
```

`host.exec` finds commands in the PATH of your login shell, so `["dinky", "workspace", "2"]` runs `/opt/homebrew/bin/dinky`. Subscribe to `session` to act when the screen is locked or unlocked.

## Share a plugin

Put the plugin folder at the root of a git repository and push it. Others install it with:

```sh
gary plugin add https://github.com/you/gary-hello.git --enable
```

`gary plugin add` also takes a local repository path, a `file://` URL, or a plain folder, which it copies. It clones into a staging folder and validates the plugin. It refuses an id that is already installed and any `gary.` id. It then prints a warning that plugins run unsandboxed, lists the capabilities in `uses` and `subscribes` with their macOS permissions, and moves the folder to `~/.config/gary/plugins/<id>`. It never runs plugin code.

| Command                                               | What it does                                                                                                                                       |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gary plugin list`                                    | Lists installed plugins, whether `shell.json` enables them, and where they came from.                                                              |
| `gary plugin enable <id>`, `gary plugin disable <id>` | Edits `~/.config/gary/shell.json`. A bar widget goes to the right of the bar.                                                                      |
| `gary plugin update <id> [--yes]`                     | Fetches, shows the log and the diff, validates the new revision, and fast-forwards. It refuses local changes. Without a terminal it needs `--yes`. |
| `gary plugin remove <id>`                             | Moves the folder to the Trash and drops the id from `shell.json`. Settings stay.                                                                   |
| `gary plugin types [folder]`                          | Writes `gary.d.ts` and `manifest.schema.json`.                                                                                                     |

## Grant permissions

Some capabilities need a macOS permission, such as Accessibility for `tray` or Full Disk Access for `focus`. macOS grants it to Gary itself, so install Gary with `just install`, which keeps it at `~/Applications/Gary.app` where grants stick across rebuilds. `gary permissions` lists each permission, whether Gary has it, and the capabilities and enabled plugins that need it. `gary permissions request <name>` shows the macOS prompt, or opens the System Settings pane where macOS has none. `gary onboarding` opens the same list as a window that says what each permission lets your plugins do, with an Allow button for each. Gary opens it on first launch and when an enabled plugin needs a permission it lacks.

## Reference

Run `gary skill show` for the full reference: concepts, every manifest field, `shell.json`, module exports, `state`, `host`, nodes, `surface`, the theme, each capability's functions, topics, types, and macOS permissions, and every command. The text comes from the installed Gary, so it matches that version, and it is the guide that `gary skill setup` points coding agents to.
