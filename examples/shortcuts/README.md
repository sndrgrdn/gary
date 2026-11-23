# Shortcuts

A service that opens apps with global shortcuts read from its settings. It registers each combination with `host.hotkeys` from `gary:effect`, and `host.apps.activate` starts the app or brings it to the front. Without settings, Control-Option-F opens Finder and Control-Option-T opens Terminal.

Copy it with `gary plugin new you.shortcuts --from shortcuts`, and set your own shortcuts in `~/.config/gary/shell.json`:

```json
{ "settings": { "you.shortcuts": { "shortcuts": { "ctrl+alt+m": "com.apple.Music" } } } }
```

Gary reloads the plugin when you save `shell.json`, and logs a combination that another app already holds. Press one with `gary key you.shortcuts ctrl+alt+m`. Run `npm install` in the copy to type-check it.
