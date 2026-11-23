# Examples

Small plugins that each show one part of Gary. Gary.app bundles them in `Contents/Resources/examples`, but Gary does not load them. Copy one under your own id to try it, then edit the copy:

```sh
gary plugin new you.timer --from timer
gary toggle you.timer
```

`gary plugin new --from` copies the example to `~/.config/gary/plugins/you.timer`, replaces `example.timer` with your id in every file, writes fresh types, and enables the plugin. A bar widget goes to the right of the bar. Gary reloads the plugin each time you save a file in the copy.

## Bar widgets

| Example              | Kinds               | Shows                                                                                                       |
| -------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------- |
| [`load`](load)       | bar-widget          | Running a command with `host.exec` on a timer, with plain promises.                                         |
| [`disk`](disk)       | service, bar-widget | A service written with Effect that publishes a typed value, and a widget that subscribes to it.             |
| [`weather`](weather) | bar-widget          | `fetch` and `Schema` from `gary:effect`, settings from `shell.json`, and a refresh when the screen unlocks. |
| [`popover`](popover) | bar-widget, panel   | Right-click, middle-click, scroll, and a tooltip on a widget, and a panel that opens attached below it.     |

## Panels and menus

| Example                | Kinds | Shows                                                                                                  |
| ---------------------- | ----- | ------------------------------------------------------------------------------------------------------ |
| [`today`](today)       | panel | Subscribing to the `clock` and `battery` topics.                                                       |
| [`timer`](timer)       | panel | Buttons, a slider, a progress bar, `host.storage`, and `keepLoaded`.                                   |
| [`osd`](osd)           | panel | Two surfaces of one module shown at once, and the volume keys through `mediakeys`.                     |
| [`gallery`](gallery)   | panel | Gradients, a `shape` progress ring, charts, a calendar `grid`, loops, blur, blend, and a Metal shader. |
| [`launcher`](launcher) | menu  | A full-display picker with an `input`, arrow keys, `hoverAction`, and a manifest hotkey.               |

## Services

| Example                  | Kinds   | Shows                                                                            |
| ------------------------ | ------- | -------------------------------------------------------------------------------- |
| [`shortcuts`](shortcuts) | service | Global hotkeys read from settings with `host.hotkeys`, and `host.apps.activate`. |

## Larger plugins

[sndrgrdn/gary-plugins](https://github.com/sndrgrdn/gary-plugins) holds a complete desktop built on Gary: about twenty plugins that replace the macOS menu bar with an Omarchy-style bar. Read them for patterns these examples leave out:

| Plugin                                                                                            | Shows                                                                                          |
| ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| [`sndrgrdn.audio`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.audio)             | A bar widget that opens a menu with volume sliders, devices, and AirPlay speakers.             |
| [`sndrgrdn.clipboard`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.clipboard)     | A clipboard history service with a picker that pastes into the previous app.                   |
| [`sndrgrdn.dinky`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.dinky)             | A service that asks a window manager for its workspaces and publishes them to other plugins.   |
| [`sndrgrdn.launcher`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.launcher)       | A launcher that ranks apps by use, and calculates and converts units and currencies.           |
| [`sndrgrdn.menu`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.menu)               | A main menu that takes screenshots and recordings, reads text and QR codes, and picks colours. |
| [`sndrgrdn.now-playing`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.now-playing) | A widget that leaves the bar when nothing plays, and a menu with artwork and a seek bar.       |
| [`sndrgrdn.theme`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.theme)             | A theme switcher that writes `palette.toml`, sets the wallpaper, and themes other apps.        |
| [`sndrgrdn.tray`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.tray)               | The menu bar icons of other apps in a drawer in the bar.                                       |

Install them all with `gary plugin install git:github.com/sndrgrdn/gary-plugins`. To start from one, copy its folder into `~/.config/gary/plugins` and change its id in `manifest.json` and in the files that name it.

## Documentation

- [Write plugins](../docs/plugins.md)
- [Test plugins](../docs/testing.md)
- [Share and install packages](../docs/packages.md)
