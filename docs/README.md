# Gary documentation

Gary is a macOS shell that you build from TypeScript plugins. It draws a bar along the top of each display, and panels, overlays, menus, and background services, from plugins that you write, install, or ask an agent to write.

## Get started

- [Install Gary](install.md) with the install script, Homebrew, or from source, and grant its permissions.
- Follow the [quick start](../README.md#quick-start) to create your first plugin.
- Paste the [agent prompt](../README.md#for-agents) into your coding agent to have it set up Gary for you.

## Build plugins

- [Write plugins](plugins.md): kinds, surfaces, topics, entry files, layout, input, Effect, and drawing.
- [Test plugins](testing.md): drive a plugin, print its node tree, capture it, and read the log.
- [Capabilities and permissions](capabilities.md): what each capability gives a plugin, and the permission it needs.
- [Examples](../examples): small plugins to copy, and larger ones to read.

## Set up your shell

- [Configure the shell](configuration.md): the bar's sections, enabled plugins, plugin settings, and the files Gary uses.
- [Themes](themes.md): the palette, colors, styles, fonts, spacing, and the bar.
- [Packages](packages.md): install, update, and publish plugins from git, npm, or a folder.

## Work on Gary

- [Develop Gary](development.md): build, check, measure, and release Gary itself.
- [Research notes](research): design notes written while building Gary. Each one describes Gary at the commit that it names.

## Look up the reference

The installed Gary prints a reference that matches its version:

- `gary help` lists every command.
- `gary skill show` prints the guide for coding agents.
- `gary skill show <topic>` prints one topic, such as `manifest`, `plugin`, `nodes`, `theme`, or a capability such as `audio`.
- A plugin's `gary.d.ts` declares every field and function that the plugin can use.
