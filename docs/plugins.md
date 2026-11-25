# Write plugins

A plugin is a folder with a `manifest.json` and one entry file per kind. Gary runs each entry file in its own JavaScriptCore context, calls `render(state)`, and draws the node tree that `render` returns with SwiftUI. Entry files are ES modules in TypeScript (`.ts` or `.tsx`) or JavaScript (`.js`).

This guide explains how plugins work and how to write one. [Test plugins](testing.md) covers checking a plugin in the running Gary, and `gary skill show <topic>` prints the full reference for your version.

## Create a plugin

1. Scaffold a plugin. Start from the [example](../examples) closest to what you want, or from a kind:

   ```sh
   gary plugin new you.weather --from weather
   gary plugin new you.hello
   gary plugin new you.music --kind bar-widget,panel
   ```

   Gary writes `~/.config/gary/plugins/<id>/` with `manifest.json`, one entry file per kind, `gary.d.ts`, `manifest.schema.json`, `tsconfig.json`, and `README.md`. A plugin with a service also gets a `package.json` for the Effect types. Gary enables the plugin in `~/.config/gary/shell.json`. A bar widget goes to the bar section that the manifest's `bar` field names, `right` by default. Without `--kind` or `--from`, the plugin is one bar widget.

2. Edit an entry file and save it. Gary reloads the plugin within about 40 ms. If the new version fails, Gary logs the reason and keeps the running version.

3. After you change `uses` or `subscribes` in `manifest.json`, refresh the types:

   ```sh
   gary plugin types ~/.config/gary/plugins/you.weather
   ```

4. Type-check the folder, then run the checks that Gary runs when it loads plugins:

   ```sh
   npx -p typescript tsc -p ~/.config/gary/plugins/you.weather
   gary plugin validate ~/.config/gary/plugins/you.weather
   ```

   For a plugin with a `package.json`, run `npm install` in its folder first, and then `npx tsc -p .`.

To scaffold outside the plugins folder, such as in a git repository, pass `--dir <folder>`. Gary records that folder in `packages` in `shell.json` and loads it in place.

## Plugin ids and kinds

A plugin id has two or more dot-separated parts of lowercase letters, digits, and hyphens, such as `you.weather`. The `gary.` prefix is reserved for the built-in plugins.

The manifest's `kinds` lists what the plugin runs as, and `entryPoints` names the file for each kind:

| Kind         | Runs as                                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------------------------- |
| `bar-widget` | A view in the built-in bar. `shell.json` places it in a bar section. When `render` returns `null`, it takes no space. |
| `bar`        | A whole bar that replaces the built-in bar.                                                                           |
| `panel`      | A window that the plugin, a command, or another plugin shows and hides.                                               |
| `overlay`    | A panel that covers the whole display above other windows.                                                            |
| `menu`       | A panel that takes keys, and hides when the user clicks outside it or presses Escape.                                 |
| `service`    | A script with no view. It publishes values for other plugins, holds hotkeys, and answers `gary call`.                 |

```json
{
  "$schema": "./manifest.schema.json",
  "schemaVersion": 1,
  "id": "you.music",
  "name": "Music",
  "version": "0.1.0",
  "kinds": ["bar-widget", "panel"],
  "entryPoints": { "bar-widget": "widget.tsx", "panel": "panel.tsx" },
  "subscribes": ["nowplaying"],
  "uses": ["nowplaying"]
}
```

Each kind runs in its own context, so kinds share no variables. They share the manifest. `uses` applies to every kind, and so does `subscribes` unless it lists topics per kind, such as `{ "panel": ["nowplaying"], "bar-widget": [] }`. Other manifest fields set `keepLoaded`, global `hotkeys`, the `mediakeys` a kind takes over, the `surfaces` of each kind, and the `bar` section a new widget goes to. `gary skill show manifest` describes every field.

## Lifecycle

1. Gary loads a kind and runs its entry file once from the top.
2. Gary delivers the current value of each subscribed topic to `onTopic`.
3. Gary calls `render(state)` once per display.
4. After each handler, timer, host callback, and topic change, Gary calls `render` again and redraws only what changed.

Enabled bar widgets, bars, and services load when Gary starts. A panel, overlay, or menu loads when it is first shown, and stops when its last surface hides, unless the manifest sets `keepLoaded`. A call, hotkey, or media key loads a hidden one, and Gary stops it a minute after the last one.

Saving `manifest.json`, a `.ts`, `.tsx`, `.js`, or `.metal` file in the plugin folder reloads the plugin. A reload starts the module again from the top. A call that runs longer than 100 ms of CPU time stops the plugin. A stopped bar widget, bar, or service restarts after 1 second, and a stopped surface loads again when it is next shown. After 6 failures in 60 seconds, Gary disables the plugin until its files change. A plugin that spends more than 1 second of CPU time in a minute, or makes two calls longer than 16 ms within a minute, reloads once on a JavaScript engine of its own, so it cannot delay other plugins; `gary stats` shows it as `own`.

## Write entry files

An entry file's default export is an object. `satisfies Gary.BarWidget`, or the type for your kind, makes TypeScript check `state`, the handlers, and the node tree:

```tsx
let clicks = 0;

export default {
  render() {
    return <text action="count">{`Clicked ${clicks} times`}</text>;
  },

  onAction(action) {
    if (action === "count") {
      clicks += 1;
    }
  },
} satisfies Gary.BarWidget;
```

- Keep state that survives renders in module variables. Keep values that survive reloads and restarts in `host.storage`.
- Keep `render` pure and fast. Do slow work in timers, promises, or Effect, store the result in a variable, and let the next render show it.
- Split a plugin into files with relative imports, such as `import { parse } from "./parse"`. Gary finds `.ts`, `.tsx`, and `.js` files and `index` files in folders. The only other import is `gary:effect`. An npm package fails the load with an error that names it.
- There is no DOM, no `console`, and no Node.js API. Log with `host.log`. Run commands with `host.exec`, read files with the `files` capability, and fetch URLs with the `network` capability.
- A module cannot use `await` at its top level. Start async work in a function that you call, in a handler, or in the `effect` field.
- `setTimeout`, `setInterval`, `clearTimeout`, and `clearInterval` work as in a browser.
- `TextEncoder` and `TextDecoder` encode and decode UTF-8 only.

Gary compiles TypeScript and JSX with a bundled copy of [sucrase](https://github.com/alangpierce/sucrase), keeps line numbers so that errors point at your source, and caches the result. Gary does not type-check, so run `tsc`.

### The default export

| Field                       | Gary calls it                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------- |
| `render(state)`             | After every change, once per display. It returns a node. A service needs no `render`.             |
| `onAction(action, payload)` | When the user clicks a node, moves a slider, types in an input, or moves the pointer onto a node. |
| `onKey(key)`                | When a focused surface gets a key that no input takes. Return `true` when the plugin handled it.  |
| `onScroll(event)`           | When the user scrolls over a panel, overlay, or menu, or over a node with `scrollAction`.         |
| `onHotkey(id)`              | When a manifest hotkey fires.                                                                     |
| `onTopic({ topic, value })` | When a subscribed topic changes, and once per topic at load.                                      |
| `onMediaKey(event)`         | When a key that the manifest's `mediakeys` lists is pressed.                                      |
| `methods`                   | Functions that `gary call` and `host.call` run.                                                   |
| `effect`                    | The plugin's long-running Effect program, when the module imports `gary:effect`.                  |
| `surface`, `surfaces`       | Where a panel, overlay, or menu shows.                                                            |

Each handler also gets `state` as its last argument. `gary skill show plugin` describes each field, every `state` field, and every `host` function.

## Read state

`state` holds what the plugin subscribes to, its settings, and the theme:

- `state.<topic>` is the value of a capability topic, such as `state.battery` or `state.wifi`. It is `undefined` until the first value arrives.
- `state["<plugin id>"]` is the last value that another plugin, or this one, published with `host.publish`.
- `state.settings` is the plugin's object from `settings` in `shell.json`. Gary reloads the plugin when it changes.
- `state.theme` holds the resolved colors, the `spacing` scale, and the `radius` scale.
- `state.display` and `state.surface` say which display and which surface `render` draws.

A topic with `available: false` cannot read its data, and gives the reason, such as a missing permission, in `reason`.

## Lay out nodes

`render` returns a tree of plain objects, such as `{ type: "text", text: "Hi" }`. In a `.tsx` file, write the same tree in JSX: `<row gap={8}><icon symbol="cpu" /><text>{load}</text></row>`. A lowercase tag is a node type, child tags become `children`, and the text inside `<text>` becomes `text`. A capitalized tag calls your own function with its attributes, so `<Button action="start" label="Start" />` runs `Button({ action: "start", label: "Start" })`. `gary.d.ts` types each tag, so a misspelled attribute is a `tsc` error.

A `row` is a horizontal stack, a `column` is a vertical stack, a `stack` layers its children from its top left corner, and a `spacer` takes the free space. The other node types are `scroll`, `button`, `text`, `icon` for an SF Symbol, `image`, `slider`, `progress`, `input`, `grid`, `shape`, `chart`, and `shader`. `gary skill show nodes` lists the fields of each.

Every node takes these style properties, as does every style in `theme.json`:

| Property                                  | Value                                                                                                                                                                   |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `style`                                   | The name of a theme style, such as `"dim"`, `"title"`, or `"panel"`. A property on the node overrides the same property in its style.                                   |
| `color`, `background`, `font`, `fontSize` | Theme color names or color expressions, a theme font name, and a size in points. `background` also takes a gradient.                                                    |
| `padding`                                 | One number for every side, `[vertical, horizontal]`, or `[top, right, bottom, left]`.                                                                                   |
| `width`, `height`, `minWidth`, `gap`      | Sizes in points, padding included. `gap` is the space between children.                                                                                                 |
| `radius`, `opacity`                       | The corner radius in points, and the opacity from 0 to 1.                                                                                                               |
| `align`                                   | `"leading"`, `"center"`, or `"trailing"`: where the content sits in a node wider than its content, and how wrapped lines align.                                         |
| `lines`, `truncate`                       | The most lines a text shows, and where it cuts text that does not fit.                                                                                                  |
| `x`, `y`, `zIndex`                        | Points to move the node without moving its siblings, and the order of overlapping siblings. In a `stack` they place the child.                                          |
| `scale`, `rotation`                       | Draws the node larger, smaller, or turned clockwise in degrees around its center, without changing its layout size.                                                     |
| `animation`, `duration`                   | `"smooth"`, `"spring"`, or `"none"`: how the node animates what changes inside it between renders, and the length in seconds. Reduce Motion turns it off.               |
| `transition`                              | `"opacity"`, `"scale"`, or `"none"`: how a child appears and disappears.                                                                                                |
| `material`, `colorScheme`                 | `"vibrant"`, `"glass"`, or `"none"`: a material behind the node, inside its `radius`. `"dark"` or `"light"` sets the appearance of the node and its children.           |
| `clip`, `border`, `shadow`                | `clip: true` cuts the content to the rounded `radius`. `border` is `{ color, width }` and `shadow` is `{ color, radius, y }`.                                           |
| `blur`, `blend`                           | `blur` blurs the node by a radius in points. `blend` mixes its colors with what is under it, such as `"multiply"`, `"screen"`, or `"plusLighter"`.                      |
| `loop`                                    | `{ opacity, scale, rotation, x, y, duration, reverse }`: an animation that repeats without calling `render`. Each property is `[from, to]`. Reduce Motion turns it off. |
| `fit`                                     | `"fit"` or `"fill"`: how an `image` fills its size.                                                                                                                     |

A node also takes `hovered` and `pressed`: objects of style properties that apply while the pointer is over the node, and while a node with `action` is held down.

Use theme style and color names, such as `style="dim"` or `color="accent"`, instead of hex colors, so that your plugin follows the user's palette. Take spacing and corner radii from `state.theme.spacing` and `state.theme.radius`, so that a theme respaces every plugin alike. [Themes](themes.md) lists the defaults.

A `text` node is exactly as wide as its text, with no padding of its own. This row centers each workspace number in a 20-point cell:

```tsx
<row gap={1}>
  {[1, 2, 3].map((n) => (
    <text key={String(n)} width={20} align="center">
      {n}
    </text>
  ))}
</row>
```

Give siblings unique `key` values, so that Gary keeps each child's state, such as hover or typed text, when their order changes.

A path that does not start with `/` or `~` is relative to the plugin folder, in an `image` or `shader` node, the `files` functions, and `host.wallpaper.set`. So a plugin finds the files it ships wherever it is installed.

## Handle input

| Field on a node | Sends                                                                                                                                                           |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `action`        | A click to `onAction`. On a `slider`, the new value as the user drags.                                                                                          |
| `rightAction`   | A right click to `onAction`.                                                                                                                                    |
| `middleAction`  | A middle click to `onAction`.                                                                                                                                   |
| `hoverAction`   | `true` to `onAction` when the pointer moves onto the node, and `false` when it leaves. A node that appears under a still pointer waits for the pointer to move. |
| `scrollAction`  | A scroll over the node to `onScroll`, with the name in `event.action`.                                                                                          |
| `tooltip`       | Text that Gary shows below the node when the pointer rests on it.                                                                                               |

An `input` sends its text to the action named by `change` on each edit, and to the action named by `submit` on Return. A menu, or a surface with `focusable: true`, sends other keys to `onKey`, such as `down`, `escape`, or `cmd+k`. Escape hides a menu or overlay unless `onKey` returns `true`.

A manifest hotkey, such as `{ "id": "open", "keys": "ctrl+alt+space" }`, calls `onHotkey("open")`, loading the plugin if needed. To read keys from settings instead, register them while the plugin runs with `host.hotkeys`, as the [`shortcuts`](../examples/shortcuts) example does.

The [`popover`](../examples/popover) example uses the click, scroll, and tooltip fields, and the [`launcher`](../examples/launcher) example uses an input, `onKey`, `hoverAction`, and a hotkey.

## Show panels, overlays, and menus

The `surface` field of the default export places a panel, overlay, or menu: its `anchors` to display edges, `margins`, size, `layer`, `background`, and whether it takes keys. `gary skill show nodes` lists every surface field.

```tsx
export default {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },
  render: () => <text style="title">Hello</text>,
} satisfies Gary.Panel;
```

- `host.show()`, `host.hide()`, and `host.toggle()` show and hide the plugin's surface from any of its kinds, so a bar widget opens its own panel with `host.toggle()`. `gary summon`, `gary hide`, and `gary toggle` do the same from the terminal.
- A surface with `attach: true` opens centered below the node whose click called `host.show()` or `host.toggle()`, such as a bar widget.
- A surface with `background: "backdrop"` and `anchors` on every edge covers the display, centers the root node, and hides when the user clicks outside it. Use it for launchers and pickers.
- To show several windows of one kind at once, such as a settings panel and an on-screen display, export `surfaces`, which maps each surface name to a `surface` object, and list the names in the manifest's `surfaces`. `render` gets the name in `state.surface`, and `host.show("osd")` or `gary summon you.music:osd` acts on one surface. The [`osd`](../examples/osd) example does this.
- Given a surface address, such as `host.toggle("you.music")` or `host.toggle("you.music:osd")`, the functions act on another enabled plugin's surface.

## Share values between kinds and plugins

Kinds and plugins share no variables. Pick one of these ways to pass values:

- **Publish a topic.** `host.publish(value)` publishes a JSON value under the plugin's id. Any plugin, the same one included, lists that id in `subscribes` and reads `state["you.source"]`. Export `type Topic` from a `topic.ts` at the root of the publishing plugin, so that `gary plugin types` types `host.publish` and every subscriber's `state`. The [`disk`](../examples/disk) example does this.
- **Call a method.** `host.call({ kind: "panel" }, "refresh")` runs a function from another kind's `methods`, and `host.call({ plugin: "you.recorder" }, "start")` runs one from another plugin. It returns a promise of the result.
- **Store a value.** `host.storage` keeps JSON values per plugin, shared by its kinds, in `~/Library/Application Support/Gary/storage/<id>.json`. If that file is not a JSON object, Gary logs it, renames it to `<id>.corrupt-<time>.json`, and starts the plugin's storage empty.

## Use capabilities

A capability adds functions to `host`, a topic to `state`, or both. List the functions you call in the manifest's `uses`, and the topics you read in `subscribes`. `gary.d.ts` declares only what the manifest asks for, so `tsc` catches a capability that you forgot to list. Some capabilities need a macOS permission. [Capabilities and permissions](capabilities.md) lists each one.

`host.exec` runs a command off the main thread, and finds commands in the `PATH` of your login shell, so `["dinky", "workspace", "2"]` runs `/opt/homebrew/bin/dinky`. Pass `{ stdin: text }` as its second argument to write text to the command's stdin, such as a secret that should stay out of its arguments. Subscribe to `session` to act when the screen is locked or unlocked.

## Write services and timers with Effect

Import [Effect](https://effect.website) from `gary:effect` for work that outlives one handler: polling, timers, `fetch`, streams, and `host.exec`. Put the long-running program in the default export's `effect` field. Gary runs it after load, and interrupts it, with every fiber the plugin started, when the plugin unloads or reloads. `render` stays synchronous and reads module variables.

```tsx
import { Effect, Schedule, host } from "gary:effect";

let uptime = "…";

const refresh = Effect.gen(function* () {
  const result = yield* host.exec(["/usr/bin/uptime"]);
  uptime = result.status === 0 ? result.stdout.trim() : "?";
}).pipe(Effect.catchTag("HostError", (error) => host.log(error.message)));

export default {
  effect: Effect.repeat(refresh, Schedule.spaced("1 minute")),
  render: () => <text>{uptime}</text>,
} satisfies Gary.BarWidget;
```

`gary:effect` exports Effect's modules, `host` with each function returning an Effect, `fetch`, `settings`, and `topic(name)`, a `Stream` of a subscribed topic. A handler or method can return an Effect, and Gary runs it in the plugin's scope. An Effect that fails, fails the plugin, so handle expected errors such as `HostError`. A plugin that does not import `gary:effect` never loads Effect.

To type-check a plugin that imports `gary:effect`, install the matching version of Effect in its folder with `npm install --save-dev effect@4.1.5`. The scaffold of a service, and the [`disk`](../examples/disk), [`weather`](../examples/weather), and [`shortcuts`](../examples/shortcuts) examples, include a `package.json` for it. `gary skill show effect` describes every export.

## Draw shapes, charts, grids, and shaders

Four node types draw more than text and images. The [`gallery`](../examples/gallery) example uses each of them.

| Type     | Draws                                                                                                                               |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `shape`  | SVG `paths` scaled from a `viewBox`, each with a `fill`, a `stroke`, and a `trim` that animates, so a progress ring grows smoothly. |
| `chart`  | A sparkline, area, or bar `series` with Swift Charts. `min` and `max` fix the y range, and `axes: true` adds axes.                  |
| `grid`   | Its `children` in rows of `columns` cells, such as a month calendar.                                                                |
| `shader` | A Metal function from a `.metal` file in the plugin folder, drawn into the node's frame and animated when `animated` is `true`.     |

A node's `background`, a shape path's `fill` and `stroke`, and a chart series' `color` take gradients too: `{ gradient: "linear", colors: ["accent", "panel"], angle: 90 }`, with `"linear"`, `"radial"`, or `"angular"` and two or more colors. `gary skill show drawing` describes every field.

## Look up the reference

`gary skill show <topic>` prints the full reference that ships with your version of Gary:

| Topic          | Covers                                                                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `manifest`     | Every field of `manifest.json` and `shell.json`.                                                                                                 |
| `plugin`       | The default export, `state`, and the `host` functions that every plugin has.                                                                     |
| `effect`       | `gary:effect` and its declarations.                                                                                                              |
| `nodes`        | Every node type with its fields and style properties, and the surface fields.                                                                    |
| `drawing`      | Gradients, rotation, blur, loops, and the `shape`, `chart`, `grid`, and `shader` nodes.                                                          |
| `theme`        | The styles, colors, and fonts of the installed theme.                                                                                            |
| `types`        | The core declarations that `gary plugin types` writes into `gary.d.ts`.                                                                          |
| `capabilities` | Every capability with its manifest entry, permissions, example, and types. Name one, such as `gary skill show audio`, for that capability alone. |
| `permissions`  | The macOS permissions that capabilities need.                                                                                                    |
| `commands`     | Every `gary` command.                                                                                                                            |

`gary skill show all` prints everything. A plugin's `gary.d.ts` declares every field and function the plugin can use.
