# Changelog

## Unreleased

## 0.6.0

### Upgrading

- A render with more than 1000 nodes no longer stops the plugin. Gary refuses that render, keeps the last tree on screen, and logs it once; `gary stats` counts it in `refusedRenders`.
- A plugin that spends more than 1 second of CPU time in a minute, or makes two calls longer than 16 ms within a minute, reloads once on a JavaScript engine of its own, so it cannot delay other plugins. The reload starts its module again, so keep state that must survive in `host.storage`.
- While the user has given no input for 30 seconds, the `clipboard` topic checks every 5 seconds, so a copy made without input, such as `pbcopy` from a script, can arrive up to about 6 seconds late. A copy the user makes arrives within half a second, as before.

### New

- `host.toast` takes a `glyph` in place of an SF Symbol `icon`, such as a Nerd Font glyph, drawn in the `toast-icon` style or in the theme font that `font` names, so a toast can match icons that plugins draw as text.
- `gary stats [id] [--watch]` prints what each loaded plugin has cost: CPU time in total and over the last minute, calls by cause, renders and tree size, timers, pending host calls, decoded images and memory, the longest call, and the engine it runs on. `gary report` includes it.
- `gary frames` reports whether Gary holds the display's refresh rate, with the hitch time per second, frame time percentiles, and the plugin tree, layout, image decode, or Core Animation commit behind each dropped frame. `gary frames --record <seconds>` records every frame for a fresh window. A frame only counts as dropped when Gary had something to draw.
- `gary trace --record <seconds>` or `--follow` prints what Gary does as JSON lines in order: topic publishes, plugin calls, host calls, renders, tree applies, shown and hidden surfaces, CLI requests, and dropped frames, each linked to its cause. `--topics <file>` also saves the topic values.
- `gary replay <file> [plugin]` feeds recorded or hand-written topic values back into Gary, or into one plugin, in order and with their timing, then returns to the live values. A plugin's behavior can be reproduced without the hardware state, such as a battery at 15%.
- `GARY_HOME` and `GARY_RUNTIME_DIR` run a second Gary next to the one you use, with its own config, plugins, storage, log, and socket. It leaves hotkeys, media keys, the Hyper key, the Dock, and the menu bar to your Gary unless `GARY_ISOLATED_SYSTEM=1` is set. `just isolated` starts one from a checkout.
- `gary action` and `gary hover` reach a row of a long list that is scrolled out of view by scrolling it in first, and `gary tree` marks such a row as `no frame: scrolled out of view`.

### Faster and lighter

- Gary with a full bar wakes about 25 times a minute while idle instead of about 150. The `clipboard` topic slows down after 30 seconds without input, and it and the `tray` topic stop polling while the screen is locked or asleep. The `calendar` topic checks for access every 10 seconds and on each app switch instead of every second, and Gary's remaining timers let macOS coalesce their wakeups.
- A busy plugin no longer holds up the others: plugins run below the priority of the interface, and a plugin that keeps the CPU busy moves to its own engine. A clock widget next to a plugin that spins near its time limit updated within 1 ms at the 99th percentile instead of 82 ms.
- Gary applies at most one tree per plugin per display frame, the newest, and shares a main-thread budget of 4 ms per frame among plugins. A widget that renders a thousand times a second no longer drops frames, and 16 widgets updating together drop about a quarter as many as before.
- Opening a menu drops far fewer frames: long lists build only the rows on screen, a reopened menu with an unchanged tree skips handing it to SwiftUI again, and the menu takes keyboard focus right after its first frame. Hiding no longer waits on the window server.
- Checking permissions, `gary doctor`, onboarding, and the Bluetooth, battery, clipboard, Focus, and calendar topics no longer block the main thread, and the Dock and menu bar capabilities run off it. Gary starts its topics one at a time across run loop turns.

### Fixes

- A crash or kill of Gary stops the commands it ran, such as the now playing helper, `host.exec`, and `host.spawn`, instead of leaving them running.
- A frozen app in the menu bar no longer slows each tray refresh to about 5 seconds. Gary skips that app's remaining questions after its first timeout and asks it again after 30 seconds.
- Accessibility questions to every tray and Control Center element time out after 1 second, not only those to the app itself.

## 0.5.0

### Upgrading

- In a hotkey, `delete` is forward delete, as it already was in `onKey`. Use `backspace` for the key labeled delete on a Mac keyboard. This applies to manifest `hotkeys`, `host.hotkeys`, and the `hyperkey` trigger and tap.
- `onKey` keeps Shift in a chord: Control-Shift-A arrives as `ctrl+shift+a`, not `ctrl+a`. A typed character without Control, Option, or Command still arrives as the character, so Shift-A gives `A`.
- An `image` or `shader` path that starts with `~user/`, or is empty, fails the render with the node that holds it, as such a path already fails in a host call.
- `host.watchFile` returns a handle with `stop()`, and in `gary:effect` it is a stream of the file's text that stops watching when its scope closes. It calls back about 200 ms after a change, and not for a write that leaves the text the same.
- `host.mkdir` returns true when it created the folder and false when the folder already existed, instead of null. When two processes create the same folder at once, exactly one gets true, so a folder can serve as a lock.
- Gary is signed with a Developer ID certificate and notarized by Apple, so macOS opens it without a warning and the Homebrew cask no longer removes the quarantine attribute. macOS ties permission grants to the certificate, so after this update run `gary onboarding` and allow each permission once more.

### New

- Gary runs on macOS 26 and later, down from macOS 27.2, and the Homebrew cask installs on macOS 26.
- `gary report` prints a bug report in Markdown, with the versions, `gary doctor`, `gary listPlugins`, the end of the log, and recent crash reports.
- `gary doctor` flags SketchyBar, StableBar, Übersicht, Zebar, and Barik when they run, since they draw their own bar over Gary's.
- `fetch` takes an optional second argument with a `method`, `headers`, and a `body`, so a plugin can call an API that needs an `Authorization` header or a POST.
- `host.spawn` ends a line at a carriage return as well as a newline, so a command that redraws a progress line, such as `networkQuality` under `script`, delivers each update. A CR LF pair still ends one line.
- `onKey` and `gary key` name the function keys `f1` to `f20`, and hotkeys take the `onKey` names `backspace`, `home`, `end`, `pageup`, and `pagedown`.
- `host.exec` takes an optional second argument with `stdin`, text that Gary writes to the command's stdin, so a plugin can hand a secret to a command such as `security -i` without putting it in the arguments or a temporary file.
- Every plugin has `TextEncoder` and `TextDecoder` for UTF-8, and `gary plugin types` declares them, so `new TextEncoder().encode(text)` type-checks and runs without importing `gary:effect`.
- Each `host.list` entry has `modified`, the time of its last change in milliseconds since 1970, so a plugin can tell a stale lock folder from a fresh one.
- `host.lockFile(path)` takes an exclusive `flock` lock on a file, such as `~/.grok/auth.json.lock`, and resolves with a handle whose `release()` lets it go. Another process that locks the same file waits until then, and `host.lockFile` waits for another process in turn, for up to 10 seconds. Gary releases a plugin's locks when it stops, and in `gary:effect` the lock lasts until its scope closes.

### Faster and lighter

- Gary with every plugin loaded uses about 33 MB instead of 40 MB.
- The bar widgets draw about 50 ms sooner after Gary starts. The check that decides whether to show the permissions window runs a second after start, and the Wi-Fi and Focus states are read off the main thread, instead of holding up the first draw.
- A panel or menu opens a few milliseconds sooner, the launcher about 9% (42 to 38 ms).
- A panel, overlay, or menu shown again within a minute of hiding appears in about half the time: the launcher in 23 ms instead of 39, the audio menu in 39 instead of 65, the theme picker in 34 instead of 66. Gary keeps the hidden window for that minute and draws the plugin's new tree in it. The plugin still stops and starts as before, an input shows the text the plugin gives it, and a list starts at its top. Until that minute is over the hidden window keeps the memory it drew with, such as 5 MB for the theme picker or 16 MB for the launcher with 15 results.
- Gary logs how long each topic source took to start, as `topic wifi: started in 2.5 ms`.
- `gary doctor` says under Memory whether JavaScriptCore runs on the system allocator, which saves about 4 MB, and fails when a Gary started the usual way missed it.

### Fixes

- A plugin's `host.storage` file that is not a JSON object, such as one cut short or edited by hand, is logged and renamed to `<id>.corrupt-<time>.json` next to it before storage starts empty, instead of reading as empty without a word and being overwritten by the next `host.storage.set`.
- Quitting or reinstalling Gary stops its now playing helper, a `perl` process, instead of leaving one running each time.
- Quitting Gary stops the processes that a running `host.exec` or `host.spawn` command started, such as both sides of `sh -c "a | b"` or a child it put in the background, instead of only the command itself. Stopping a command or its plugin already stopped them all.
- `gary hide`, and `host.hide()`, fail with `<id> has no surface <name>` for a surface the plugin doesn't list, as `gary summon` does, instead of printing `hidden` while the surface stays on screen. Name the surface from the manifest's `surfaces`, such as `gary hide sndrgrdn.network:speedtest`, not the kind.
- A wide widget in `notchLeft`, such as a long track title, shrinks and truncates against the `left` section instead of pushing it off the left edge of the screen.
- A bar section too wide for its room truncates instead of pushing other sections past the edge of the screen. `notchLeft` gives way first, then `center`, and `left` and `right` keep their width.
- `gary doctor` lists a subscription to an installed plugin that is not enabled as a note, not a failure, since a plugin can read a companion plugin's topic only when it runs. A subscription to a plugin that is not installed still fails.
- `host.apps.installed()` lists Finder and the apps in `/System/Library/CoreServices/Applications`, such as Keychain Access and Archive Utility.
- A `host.call` with an invalid plugin id rejects with `host.call: <id> is not a plugin id` instead of freezing every plugin on its engine.
- A `host.call` to a kind that doesn't exist, such as `pannel`, rejects and lists the kinds instead of running in another kind.
- A `gary call` or `host.call` whose plugin stops before it replies fails at once instead of after 60 seconds.
- `host.storage` keeps the writes of a plugin's bar widget, panel, and other kinds, and each kind reads the values the others wrote.
- A node keeps its children's state, such as the text in an input, when its `colorScheme`, `clip`, or `vibrant` material comes or goes.
- A node with a `hovered` or `pressed` style, or a button, keeps its children's state when hovering or pressing it adds or removes a shadow.
- The manifest schema accepts the hotkeys Gary loads, such as `f13`, and rejects the ones it refuses, such as `shift+a` or a hotkey with a newline in it.
- The Full Disk Access drag tile follows the theme's mode, colors, and spacing from launch.
- `gary doctor` checks the theme Gary shows: in the Mac's current appearance instead of always in dark mode, with the payload of `gary applyTheme`, and it names the mode it checked.
- `host.watchFile` calls back for a file created after the watch starts, and again when a file is deleted and created anew, instead of giving up after 5 seconds.
- `host.spawn`, `host.hotkeys`, `host.hyperkey`, and `host.watchFile` name the API in their errors, such as `host.hyperkey: …`, like the other host functions.
- `host.spawn` cuts a line longer than 1 MB to its first 1 MB, so a command that never prints a newline no longer grows Gary's memory without bound, and long output no longer slows down.
- A panel, overlay, or menu that a hotkey, media key, `gary call`, or `host.call` loaded while hidden stops a minute after its last use, unless it is shown or sets `keepLoaded`, instead of running until Gary quits.
- A reload that fails keeps the running version's manifest in charge, so hiding, surface names, media keys, and `gary listPlugins` follow the version that runs. Summoning a surface that only the failed manifest names fails at once instead of after 5 seconds.
- A `shell.json` change to a plugin's settings and its files loads the plugin once instead of twice.
- A `gary applyTheme` payload that the theme rejects is no longer kept, so later theme reloads no longer fail on it and the theme keeps following the Mac's appearance, `palette.toml`, and `theme.json`.

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
