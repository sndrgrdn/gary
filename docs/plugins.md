# Writing Gary plugins

A plugin is a folder with a `manifest.json` and one entry file per kind. Gary runs each entry file in its own JavaScriptCore context. It calls `render(state)` and draws the node tree that `render` returns. Entry files are TypeScript (`.ts`) or JavaScript (`.js`).

Gary.app bundles the plugins in [`examples/`](../examples) in `Contents/Resources/examples`. Gary does not load them. Copy one under your own id to start:

| Example                          | Shows                                                                                          |
| -------------------------------- | ---------------------------------------------------------------------------------------------- |
| [`load`](../examples/load)       | A bar widget that runs a command with `host.exec`.                                             |
| [`disk`](../examples/disk)       | A service that publishes a value and a bar widget that subscribes to it.                       |
| [`timer`](../examples/timer)     | A panel with buttons, a slider, a progress bar, and `host.storage`.                            |
| [`today`](../examples/today)     | A panel that subscribes to the `clock` and `battery` topics.                                   |
| [`gallery`](../examples/gallery) | A panel that draws a gradient, a progress ring, charts, a calendar grid, loops, and a shader.  |
| [`popover`](../examples/popover) | A bar widget with right-click, middle-click, scroll, and tooltip that opens an attached panel. |

The only built-in plugins are the `gary.clock` and `gary.battery` bar widgets, so a fresh install shows a bar.

## Create a plugin

1. Scaffold a bar widget and turn it on:

   ```sh
   gary plugin new you.hello
   ```

   Gary writes `~/.config/gary/plugins/you.hello/` with `manifest.json`, `widget.ts`, `gary.d.ts`, `manifest.schema.json`, `tsconfig.json`, and `README.md`. The widget appears at the right of the bar. To start from an example instead, pass `--from`, such as `gary plugin new you.timer --from timer`. Gary replaces the example's id with yours in every file.

2. Edit `widget.ts` and save. Gary reloads the plugin within about 40 ms. If the new version fails, Gary logs the reason and keeps the running version.
3. Type-check the folder:

   ```sh
   npx -p typescript tsc -p ~/.config/gary/plugins/you.hello
   ```

4. Run the checks Gary runs when it loads plugins:

   ```sh
   gary plugin validate ~/.config/gary/plugins/you.hello
   ```

For another kind, pass `--kind`, for example `--kind panel` or `--kind service,bar-widget`. To scaffold outside the plugins folder, pass `--dir <path>`. Gary then records that folder in `packages` in `shell.json` and loads it in place.

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
| `rotation`                 | Degrees to turn the node clockwise around its center without changing its layout. It animates like `scale`.                                                                                                              |
| `blur`, `blend`            | `blur` blurs the node by a radius in points. `blend` mixes its colors with what is under it: `"normal"`, `"multiply"`, `"screen"`, `"overlay"`, `"plusLighter"`, `"plusDarker"`, or `"difference"`.                      |
| `loop`                     | `{ opacity, scale, rotation, x, y, duration, reverse }`: an animation that repeats without calling `render`. Each property is `[from, to]`. Reduce Motion turns it off.                                                  |
| `fit`                      | `"fit"` or `"fill"`: how an `image` fills its size. Gary decodes images at the size they show, a file over 32 KB off the main thread. It appears when ready, faded only by the image's own `transition` and `animation`. |

`background` takes a color or a gradient: `{ gradient: "linear", colors: ["accent", "panel"], angle: 90 }`, with `"linear"`, `"radial"`, or `"angular"` and two or more colors.

A node also takes `hovered` and `pressed`: objects of style properties that apply while the pointer is over it, and while a node with `action` is held down.

`action` names what a click on a node sends to `onAction`. `rightAction` and `middleAction` do the same for a right click and a middle click. `scrollAction` sends a scroll over the node to `onScroll`, with the name in the event's `action`. `tooltip` is text that Gary shows below the node when the pointer rests on it. A surface with `attach: true` opens centred below the node whose click called `host.show()` or `host.toggle()`. The `popover` example uses each of them.

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

A path that does not start with `/` or `~` is relative to the plugin folder, in an `image` or `shader` node, the `files` functions, and `host.wallpaper.set`. So a plugin finds the files it ships wherever it is installed, in `~/.config/gary/plugins` or in a package. Gary refuses a relative path whose `..` leaves the plugin folder.

## Draw shapes, charts, grids, and shaders

Four node types draw more than text and images. The [`gallery`](../examples/gallery) example uses each of them.

| Type     | Draws                                                                                                                               |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `shape`  | SVG `paths` scaled from a `viewBox`, each with a `fill`, a `stroke`, and a `trim` that animates, so a progress ring grows smoothly. |
| `chart`  | A sparkline, area, or bar `series` with Swift Charts. `min` and `max` fix the y range, and `axes: true` adds axes.                  |
| `grid`   | Its `children` in rows of `columns` cells, such as a month calendar.                                                                |
| `shader` | A Metal function from a `.metal` file in the plugin folder, drawn into the node's frame and animated when `animated` is `true`.     |

Run `gary skill show` for every field.

## Share and install plugins

A package is a folder that holds plugins. If its root has a `manifest.json`, it is one plugin. Otherwise each folder directly inside it that has a `manifest.json` is a plugin. Push a package to a git repository or publish it to npm. Others install it with one of:

```sh
gary plugin install git:github.com/you/gary-plugins
gary plugin install git:github.com/you/gary-plugins@v1.0.0
gary plugin install https://github.com/you/gary-plugins
gary plugin install npm:gary-weather@1.2.0
gary plugin install ~/src/gary-plugins
```

`gary plugin install` fetches the package and validates its plugins without running any of them. It warns that plugins run unsandboxed, lists each plugin's capabilities with their macOS permissions, and asks before it installs. `--yes` skips the question. It then adds the source to `packages` in `~/.config/gary/shell.json` and enables each plugin. A bar widget goes to the end of the bar section named by its manifest's `bar` field, `right` by default. A plugin that `shell.json` already places or disables keeps that setting.

Gary keeps git and npm packages in `~/Library/Application Support/Gary/packages`. It clones git packages with the system `git`, and downloads npm packages from the registry without Node, checking each download against the registry's sha512 integrity. A local folder loads in place, and Gary reloads its plugins when you save, as it does for `~/.config/gary/plugins`. When Gary starts, it installs each declared package that is missing. If that fails, for example offline, Gary logs it, skips the package, and tries again on the next start.

A source identifies its package: npm by name, git by repository without the ref, and a local folder by its absolute path. So `git:github.com/you/gary-plugins@v2` replaces `git:github.com/you/gary-plugins`, and one package never loads twice. When two plugins share an id, the first one wins: built-in plugins, then `~/.config/gary/plugins`, then packages in the order `shell.json` lists them.

| Command                                               | What it does                                                                                                                                                                |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gary plugin list`                                    | Lists plugins with their version, whether `shell.json` enables them, their source, and whether the source is pinned.                                                        |
| `gary plugin enable <id>`, `gary plugin disable <id>` | Edits `~/.config/gary/shell.json`. A bar widget goes to the bar section its manifest names.                                                                                 |
| `gary plugin update [<source>]`                       | Updates every package, or one, and prints the old and new version or commit. An exact npm version, a git tag, or a commit stays put. A branch or no ref follows the remote. |
| `gary plugin remove <source\|id>`                     | Removes a package and drops its plugins from `shell.json`, or moves a plugin in `~/.config/gary/plugins` to the Trash. Settings stay.                                       |
| `gary plugin types [folder]`                          | Writes `gary.d.ts` and `manifest.schema.json`.                                                                                                                              |

## Grant permissions

Some capabilities need a macOS permission, such as Accessibility for `tray` or Full Disk Access for `focus`. macOS grants it to Gary itself, so install Gary with `just install`, which keeps it at `~/Applications/Gary.app` where grants stick across rebuilds. `gary permissions` lists each permission, whether Gary has it, and the capabilities and enabled plugins that need it. `gary permissions request <name>` shows the macOS prompt, or opens the System Settings pane where macOS has none. `gary onboarding` opens the same list as a window that says what each permission lets your plugins do, with an Allow button for each. Gary opens it on first launch and when an enabled plugin needs a permission it lacks.

## Reference

Run `gary skill show` for the full reference: concepts, every manifest field, `shell.json`, module exports, `state`, `host`, nodes, `surface`, the theme, each capability's functions, topics, types, and macOS permissions, and every command. The text comes from the installed Gary, so it matches that version, and it is the guide that `gary skill setup` points coding agents to.
