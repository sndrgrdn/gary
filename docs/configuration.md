# Configure the shell

`~/.config/gary/shell.json` says which plugins run, where bar widgets sit, and what settings each plugin gets. Gary applies a saved change at once. The `gary plugin` commands edit the file for you, and you can edit it by hand.

Without the file, the bar shows the built-in `gary.battery` and `gary.clock` widgets on the right.

## An example

```json
{
  "bar": {
    "left": ["you.workspaces"],
    "center": ["you.clock", "you.weather"],
    "right": ["you.audio", "gary.battery"]
  },
  "plugins": ["you.launcher", "you.shortcuts"],
  "disabledPlugins": ["gary.clock"],
  "settings": {
    "you.weather": { "latitude": 53.2, "longitude": 5.8 },
    "you.launcher": { "key": "cmd+space" }
  },
  "packages": ["git:github.com/sndrgrdn/gary-plugins"]
}
```

## Fields

| Field               | Meaning                                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bar`               | `left`, `center`, `right`, and `notchLeft`: lists of bar widget ids, in order. Naming a widget enables it. Naming any section replaces the default sections.             |
| `bar.revealMenuBar` | `true` by default: when the pointer reaches the top edge of a display, the bar hides so that macOS can show its menu bar. `false` keeps the bar over the macOS menu bar. |
| `plugins`           | Ids of enabled plugins that are not bar widgets, such as panels, menus, and services.                                                                                    |
| `disabledPlugins`   | Ids to turn off, built-in plugins included.                                                                                                                              |
| `settings`          | `{ "<id>": { ... } }`. Each plugin reads its object as `state.settings`, and Gary reloads the plugin when its object changes.                                            |
| `packages`          | Plugin packages that Gary installs and loads. [Packages](packages.md) describes the sources.                                                                             |

On a display with a notch, `notchLeft` ends at the notch's left edge and `center` starts at its right edge. Without a notch, `center` is centered and `notchLeft` ends just left of it. When the sections do not fit, `notchLeft` shrinks first, then `center`, and `left` and `right` keep their width, so no section crosses the screen edge, the notch, or another section. A plugin that hides the macOS menu bar with the `menubar` capability keeps the bar in place.

A plugin's README lists the settings it reads. `gary doctor` reports mistakes in `shell.json`, and Gary logs the fields that it ignores.

## Files Gary uses

| Path                                           | Holds                                                                         |
| ---------------------------------------------- | ----------------------------------------------------------------------------- |
| `~/.config/gary/shell.json`                    | Enabled plugins, the bar's sections, plugin settings, and packages.           |
| `~/.config/gary/plugins/`                      | Your plugins, one folder each. Gary reloads a plugin when you save its files. |
| `~/.config/gary/theme.json`                    | Your changes to the built-in theme. [Themes](themes.md) describes it.         |
| `~/.config/gary/palette.toml`                  | Your color palette.                                                           |
| `~/Library/Application Support/Gary/storage/`  | What plugins keep with `host.storage`, one JSON file per plugin.              |
| `~/Library/Application Support/Gary/packages/` | Installed git and npm packages.                                               |
| `~/Library/Caches/Gary/transpiled/`            | Compiled plugin code. Gary recreates it when needed.                          |
| `~/Library/Logs/gary.log`                      | The log of the running Gary.                                                  |
