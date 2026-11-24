# Test plugins

The `gary` command drives a plugin the way a user would and shows what it draws. It talks to the running Gary over a socket, so it needs no Accessibility or Screen Recording permission for your terminal. Coding agents test plugins with the same commands.

## Drive a plugin

Name a plugin by its id, and a kind by `<id>/<kind>`, such as `you.launcher/menu`. A command that acts on a node names the node by one of its actions.

| Command                                        | Does                                                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `gary summon you.hello`, `gary hide you.hello` | Shows or hides a panel, overlay, or menu. Add `:<surface>` for a surface other than `main`.             |
| `gary toggle you.hello`                        | Shows a hidden surface, or hides a shown one.                                                           |
| `gary action you.hello/panel <action>`         | Clicks the shown node with that `action`, `rightAction`, or `middleAction`. Pass a number for a slider. |
| `gary click you.hello/panel <x> <y>`           | Clicks a point of the surface, in points from its top left corner, such as empty space.                 |
| `gary key you.hello/menu s a f enter`          | Types and presses keys. A key that the plugin holds as a hotkey presses that hotkey.                    |
| `gary hover you.hello/menu <hoverAction>`      | Moves the pointer onto the node with that `hoverAction`. Add `off` to move it away.                     |
| `gary scroll you.hello/panel [action] 3`       | Scrolls over a node or the surface. Add `--precise` for a trackpad gesture.                             |
| `gary call you.hello <method> [args...]`       | Runs a function from the plugin's `methods`, and prints its result.                                     |
| `gary reloadPlugins you.hello`                 | Reloads the plugin from disk.                                                                           |

`gary key` is the only way to test a hotkey, because macOS does not fire hotkeys for synthesized key events. For example, these commands open a copy of the [`launcher`](../examples/launcher) example, type "cal", and open the first match:

```sh
gary key you.launcher ctrl+alt+space
gary key you.launcher/menu c a l enter
```

To inspect a value that the plugin keeps inside, add a function to `methods` that returns it, and run it with `gary call`.

## See what a plugin draws

| Command                                       | Prints                                                                                          |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `gary tree you.hello/panel`                   | Every shown node with its key, text, frame in points, and the colors and font it is drawn with. |
| `gary capture you.hello/panel /tmp/hello.png` | The surface as a PNG at the display's scale, without other windows.                             |
| `gary listPlugins`                            | One line per plugin: its id, version, origin, and the state of each kind.                       |

Use `gary tree` to check layout and colors exactly, instead of measuring a screenshot. `gary capture` needs no Screen Recording permission, but it leaves out blur and materials, which macOS draws later. For those, take a screenshot of a rectangle with `screencapture -x -R x,y,width,height`, which needs Screen Recording for your terminal.

`gary listPlugins` shows each kind in one of these states:

| State              | Means                                                                          |
| ------------------ | ------------------------------------------------------------------------------ |
| `running`          | A bar widget, bar, or service runs.                                            |
| `stopped`          | A bar widget, bar, or service waits to restart after a failure.                |
| `shown`            | A panel, overlay, or menu is on screen.                                        |
| `hidden`           | A panel, overlay, or menu is not loaded.                                       |
| `paused`           | A hidden surface that `keepLoaded` or a call in the last minute keeps running. |
| `not-in-bar`       | An enabled bar widget that no bar section in `shell.json` names.               |
| `inactive`         | A bar that another enabled bar replaces.                                       |
| `disabled`         | The plugin is not enabled in `shell.json`.                                     |
| `failed(reason)`   | The kind failed to load or run.                                                |
| `disabled(reason)` | The kind failed 6 times in 60 seconds. Gary tries again when its files change. |

A kind with several surfaces shows a state per surface, such as `panel:main=shown,osd=hidden`.

## Read the log

Gary writes `host.log` lines, load failures, and stopped plugins to `~/Library/Logs/gary.log`. Plugin lines start with `plugin <id>/<kind>:` for loads and failures, and `plugin <id>:` for `host.log`. Follow one plugin after each save:

```sh
tail -f ~/Library/Logs/gary.log | grep --line-buffered 'plugin you.hello'
```

## Find problems

- `gary doctor` reports problems with private APIs, the allocator JavaScriptCore runs on, permissions, plugins, `shell.json`, and the theme, and other bars that are running, such as SketchyBar, which draw over Gary's bar.
- `gary stats [id] [--watch]` prints one JSON line per loaded plugin kind with what it has cost since it loaded. `engine` names the JavaScript engine it runs on: `bar`, shared by the bar plugins, `other`, shared by the other kinds, or `own`. A plugin that spends over a second of CPU in a minute reloads on its own engine, so it no longer delays the plugins it shared with. `cpuMs` gives the CPU time spent in the plugin's JavaScript, in `total` and over the `last60s`. `entries` counts the runs of its JavaScript by cause: `load`, `render`, `timer`, `topic`, `action` for clicks, keys, scrolls, hotkeys, and media keys, `call` for `gary call` and `host.call`, and `host` for a settled host promise, such as `host.exec` or `fetch`, or another host callback. `longestEntryMs` is the longest single run, and `overTimeLimit` counts the runs stopped after 100 ms. `renders` counts render calls, and `lastRenderNodes` is the node count of the latest one. A tree over `nodeCap` nodes is refused and the last tree stays on screen; `refusedRenders` counts those renders, and the log says when a run of them starts. `timers` gives the fires in the last 60 seconds and the live `timeouts` and `intervals`. `pendingHostCalls` counts the host promises that have not settled yet, by name. `memory` is what Gary holds for the kind on screen: its `treeNodes`, the decoded `images` it shows and their `imageBytes`, and its `views` and `layers`. With `--watch` it prints the lines again every second. Use it to find the plugin that wakes Gary while idle, takes CPU, or keeps growing.
- `gary report` prints a bug report in Markdown: the versions, `gary doctor`, `gary listPlugins`, `gary stats`, the last 100 log lines, and recent crash reports. Paste it into a [bug report](https://github.com/sndrgrdn/gary/issues/new) after you remove anything personal.
- `gary frames` reports, per display, whether Gary held the refresh rate over the last minute: the frames, the hitch time in milliseconds per second, the frame time p50, p99, and max, and for each dropped frame the main-thread work inside it, such as a plugin's tree, layout, an image decode, or the Core Animation commit. `gary frames --record 10` records every frame for 10 seconds and reports only those. Outside a recording, Gary records frames only while a surface animates, fades, or scrolls, so a widget that redraws without animating and an idle Gary cost nothing.
- `gary permissions` lists each macOS permission, whether Gary has it, and the enabled plugins that need it.
- `gary plugin validate <folder>` runs the checks that Gary runs when it loads a plugin.
- When `gary` prints `not running`, start Gary with `open -a Gary`.

To test without touching the Gary you use, run `just isolated` from a checkout. It starts a second Gary with its own config, plugins, log, and socket, as [Develop Gary](development.md#run-an-isolated-gary) describes. It prints its log in the terminal, and `gary` reaches it when `GARY_RUNTIME_DIR` names its runtime folder.

To run Gary in the foreground with its log in the terminal, quit it with `gary quit` and run `gary app`. macOS then checks your terminal's permissions instead of Gary's.
