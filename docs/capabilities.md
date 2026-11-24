# Capabilities and permissions

A capability gives a plugin part of the Mac. It adds functions to `host`, a topic to `state`, or both. A plugin lists the functions it calls in its manifest's `uses`, and the topics it reads in `subscribes`:

```json
{ "uses": ["audio"], "subscribes": ["audio", "battery"] }
```

Gary installs only the capabilities that a plugin's manifest names, and `gary plugin types` declares only those in `gary.d.ts`. A capability topic runs only while a loaded kind subscribes to it. `gary skill show <capability>` prints the full reference for one capability, with an example entry file and its types.

## Capabilities

In the **Manifest** column, `uses` means the capability adds `host` functions, and `subscribes` means it adds a topic.

| Capability      | Gives                                                                                                    | Manifest         | macOS permission                      |
| --------------- | -------------------------------------------------------------------------------------------------------- | ---------------- | ------------------------------------- |
| `apps`          | The frontmost, running, and installed apps. Launch, activate, and quit an app.                           | uses, subscribes | None                                  |
| `audio`         | Audio devices, volume, mute, and the apps that play audio. Set volumes and devices, and play to AirPlay. | uses, subscribes | System Audio Recording, Accessibility |
| `battery`       | Battery percentage, charging state, and power source.                                                    | subscribes       | None                                  |
| `bluetooth`     | Bluetooth power, paired devices with their battery levels, and nearby devices. Connect and pair.         | uses, subscribes | Bluetooth                             |
| `brightness`    | The brightness of the built-in display and of external displays that support DDC. Set it.                | uses, subscribes | None                                  |
| `calendar`      | The calendars and events of the Calendar app.                                                            | uses, subscribes | Calendars                             |
| `clipboard`     | Clipboard changes. Read the clipboard, and write text, an image, or files to it.                         | uses, subscribes | None                                  |
| `clock`         | The current minute, and whether macOS shows 12-hour time.                                                | subscribes       | None                                  |
| `colorpicker`   | Pick a color from anywhere on screen with the macOS magnifier.                                           | uses             | None                                  |
| `dock`          | Reserve a screen edge that windows keep clear of, and hide or show the Dock.                             | uses             | None                                  |
| `exec`          | Run a command, or stream the output of a long-running one.                                               | uses             | None                                  |
| `files`         | Read, write, list, remove, watch, and lock files.                                                        | uses             | None                                  |
| `focus`         | Whether a Focus, such as Do Not Disturb, is on.                                                          | subscribes       | Full Disk Access                      |
| `hotkeys`       | Global hotkeys registered while the plugin runs, such as ones read from settings.                        | uses             | None                                  |
| `hyperkey`      | Make a key, Caps Lock by default, a Hyper key that adds Control, Option, and Command.                    | uses             | Accessibility                         |
| `mediakeys`     | Take over the volume, brightness, and playback keys. Set in the manifest's `mediakeys`.                  | `mediakeys`      | Accessibility                         |
| `menubar`       | Hide the macOS menu bar while the plugin runs.                                                           | uses             | None                                  |
| `network`       | A global `fetch` for http and https URLs.                                                                | uses             | None                                  |
| `notifications` | The notifications that Notification Center delivered. Open the app that sent one.                        | uses, subscribes | Full Disk Access                      |
| `notify`        | Post a macOS notification.                                                                               | uses             | Notifications                         |
| `nowplaying`    | The track that any app plays. Play, pause, skip, and seek.                                               | uses, subscribes | None                                  |
| `paste`         | Paste the clipboard into the frontmost app.                                                              | uses             | Accessibility                         |
| `permissions`   | Each macOS permission and whether Gary has it. Ask for one, and restart Gary after a grant.              | uses, subscribes | None                                  |
| `power`         | Sleep, lock the screen, restart, shut down, log out, and keep the Mac awake.                             | uses             | Accessibility, Automation             |
| `screen`        | Select a region, window, or display, capture it to a PNG, or record it to a movie.                       | uses             | Screen Recording                      |
| `session`       | Whether the screen is locked.                                                                            | subscribes       | None                                  |
| `system`        | CPU and memory use, and the seconds since the last input.                                                | subscribes       | None                                  |
| `toast`         | Show a card that Gary draws at the top right, and learn whether the user clicked it.                     | uses             | None                                  |
| `tray`          | The status items in the macOS menu bar, with their icons. Press one.                                     | uses, subscribes | Accessibility, Screen Recording       |
| `vision`        | Read the text, QR codes, and barcodes in an image file or an area of the screen.                         | uses             | Screen Recording                      |
| `wallpaper`     | The wallpaper of each display. Set it.                                                                   | uses             | None                                  |
| `wifi`          | Wi-Fi power, network, signal, and nearby networks. Scan, join, forget, and turn Wi-Fi on or off.         | uses, subscribes | Location                              |

Some permissions cover only part of a capability. For example, `power` needs Accessibility only to lock the screen, and `vision` needs Screen Recording only to read the screen. `gary skill show <capability>` says which functions need which permission.

## Permissions

macOS grants each permission to Gary itself, the app `com.sndrgrdn.gary`, not to your terminal or a plugin. Every plugin then shares the grant.

| Permission             | Name for `gary permissions request` | Capabilities                                               |
| ---------------------- | ----------------------------------- | ---------------------------------------------------------- |
| Accessibility          | `accessibility`                     | `audio`, `hyperkey`, `mediakeys`, `paste`, `power`, `tray` |
| System Audio Recording | `audio-capture`                     | `audio`                                                    |
| Automation             | `automation`                        | `power`                                                    |
| Bluetooth              | `bluetooth`                         | `bluetooth`                                                |
| Calendars              | `calendars`                         | `calendar`                                                 |
| Full Disk Access       | `full-disk-access`                  | `focus`, `notifications`                                   |
| Location               | `location`                          | `wifi`                                                     |
| Notifications          | `notifications`                     | `notify`                                                   |
| Screen Recording       | `screen-recording`                  | `screen`, `tray`, `vision`                                 |

- `gary permissions` lists each permission, whether Gary has it, and the enabled plugins that need it.
- `gary permissions request <name>` shows the macOS prompt, or opens the System Settings pane where macOS has no prompt.
- `gary onboarding` opens the **Set up Gary** window, which lists what your enabled plugins need with an **Allow** button for each. Gary opens it on first launch, and when an enabled plugin needs a permission that Gary lacks, unless you closed it with that permission still missing.

A new Screen Recording or Full Disk Access grant can need a restart of Gary. The **Set up Gary** window offers the restart. A capability that lacks a permission says so in its error, or in its topic's `reason`, with the command that asks for it.

If you run Gary from a terminal with `gary app`, macOS checks the terminal's permissions instead of Gary's.
