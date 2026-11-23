# Changelog

## Unreleased

### Upgrading

- In a hotkey, `delete` is forward delete, as it already was in `onKey`. Use `backspace` for the key labeled delete on a Mac keyboard. This applies to manifest `hotkeys`, `host.hotkeys`, and the `hyperkey` trigger and tap.
- `onKey` keeps Shift in a chord: Control-Shift-A arrives as `ctrl+shift+a`, not `ctrl+a`. A typed character without Control, Option, or Command still arrives as the character, so Shift-A gives `A`.
- An `image` or `shader` path that starts with `~user/`, or is empty, fails the render with the node that holds it, as such a path already fails in a host call.

### New

- `gary report` prints a bug report in Markdown, with the versions, `gary doctor`, `gary listPlugins`, the end of the log, and recent crash reports.
- `gary doctor` flags SketchyBar, StableBar, Übersicht, Zebar, and Barik when they run, since they draw their own bar over Gary's.
- `onKey` and `gary key` name the function keys `f1` to `f20`, and hotkeys take the `onKey` names `backspace`, `home`, `end`, `pageup`, and `pagedown`.

### Fixes

- Gary runs on macOS 26 and later, down from 27.2.
- `host.apps.installed()` lists Finder and the apps in `/System/Library/CoreServices/Applications`, such as Keychain Access and Archive Utility.
- A `host.call` with an invalid plugin id rejects with `host.call: <id> is not a plugin id` instead of freezing every plugin on its engine.
- A `host.call` to a kind that doesn't exist, such as `pannel`, rejects and lists the kinds instead of running in another kind.
- A `gary call` or `host.call` whose plugin stops before it replies fails at once instead of after 60 seconds.
- `host.storage` keeps the writes of a plugin's bar widget, panel, and other kinds, and each kind reads the values the others wrote.
- A node keeps its children's state, such as the text in an input, when its `colorScheme`, `clip`, or `vibrant` material comes or goes.
- A node with a `hovered` or `pressed` style, or a button, keeps its children's state when hovering or pressing it adds or removes a shadow.
- The manifest schema accepts the hotkeys Gary loads, such as `f13`, and rejects the ones it refuses, such as `shift+a`.
- The Full Disk Access drag tile follows the theme's mode, colors, and spacing from launch.

## 0.4.0

### Upgrading

- Plugin entry files load as ES modules. Replace `module.exports = { ... }` with `export default { ... }`.
- The `offset` style property is gone. Use `y`.
- A packages entry no longer takes the `{ "source": ... }` form.
- `gary plugin install` lists the capabilities a plugin uses and installs it without asking, so drop `--yes` from scripts.
- The built-in clock follows the Mac's 12- or 24-hour setting, and its `hour12` setting is gone.

### New capabilities

- `host.hotkeys` registers global hotkeys while a plugin runs. A hotkey can name `hyper`, which is ctrl+alt+cmd, and the keys F13 to F20.
- `host.hyperkey` turns Caps Lock into Hyper while a plugin holds it. `key` picks another key, such as `rightCommand` or `f19`, and `tap` picks the key that a quick press sends.
- The audio capability sets each app's volume and plays to AirPlay speakers. It needs the new System Audio Recording permission.
- `host.calendar` reads events and calendars, and `host.notify.post` posts a macOS notification.
- `host.toast` shows a clickable card at the top right, below the bar.
- The screen capability captures a region, window, or display to a PNG, and records one to a movie file.
- The vision capability reads text, QR codes, and barcodes in an image file or an area of the screen.
- The colorpicker capability picks a colour from the screen with the macOS magnifier.
- The power capability sleeps, locks the screen, restarts, shuts down, and logs out. `power.stayAwake` keeps the Mac awake while a plugin asks.
- The system topic gives CPU and memory use and the seconds since the last input.
- The apps capability lists installed apps, and launches, activates, and quits them.
- The clipboard takes images and files, and can mark text as concealed so clipboard managers skip it.
- Bluetooth finds nearby devices and pairs one that needs no code. Wi-Fi marks the networks this Mac joined before, and `host.wifi.forget` forgets one.
- `host.spawn` streams the output lines of a long-running command.

### Writing plugins

- Entry files can import other files, and `.tsx` files build nodes with JSX.
- `gary plugin types` writes a `tsconfig.json`, and topics are typed by name.
- `gary:effect` runs Effect 4. A handler or method can return an Effect, and a failed host call fails with a `HostError`.
- A plugin can declare several named surfaces and show each on its own, such as `gary summon you.music:osd`.
- `host.call` reaches another kind of the same plugin, or another plugin with `{ plugin }`. `host.show`, `host.hide`, and `host.toggle` take another plugin's surface address.
- `subscribes` can list topics for each kind, so a topic runs only while a kind that reads it is loaded.
- Media keys come from the manifest, so a press loads the kind that handles it.
- `host.exec` stops a command after 60 seconds, and Gary stops running commands when the plugin stops or Gary quits.

### Nodes and drawing

- New `shape`, `chart`, `grid`, and `shader` nodes draw SVG paths, sparklines and bars, fixed-column grids, and Metal shaders.
- Backgrounds take linear, radial, and angular gradients.
- Styles take rotation, blur, blend, and loops that pulse or spin a node without rendering again.
- Every node takes a right-click, middle-click, scroll, and hover action, and a tooltip.
- A surface opened with `attach` opens below the node that showed it.
- A slider sends a release action once when a drag ends. A slider or progress value can advance on its own from a rate.
- Text takes `lines` and `truncate`, and an image with its own color draws as a template in that color.
- A bar widget that renders `null` takes no space.

### Bar and theme

- The bar has a `notchLeft` section beside the notch.
- The theme sets the bar's widget gap and edge inset, and has a radius scale and a 4 pt spacing scale.
- The built-in theme maps palette colours the way Omarchy 4.5's shell does.
- Panels, overlays, and menus draw their border from their style.

### Testing from the command line

- `gary key`, `gary scroll`, `gary hover`, `gary click`, and `gary action` drive a shown surface as the user would.
- `gary tree` prints a surface's nodes with their frames and colors, and `gary capture` draws a surface into a PNG without Screen Recording.
- `gary skill show` prints a guide for agents that write plugins.

### Faster and lighter

- Gary with every plugin loaded uses about 39 MB instead of 58 MB.
- Images free their memory a minute after their surface hides.
- Gary caches transpiled plugin code, so plugins load faster after the first start.
- Large panels render faster: a 1000-node tree parses in 0.7 ms instead of 7.8 ms.

### Fixes

- The audio menu stays open while it lists AirPlay speakers.
- Editing a shader recompiles it, and an animated shader pauses while its window is hidden.
- The plugin time limit counts CPU time, so a busy Mac no longer stops a healthy plugin.
- A fresh launch no longer counts Location as a missing permission.
- A malformed entry in `shell.json` is skipped with a warning instead of rejecting the file.
- A chart whose values all reach `max` draws at the top.
