# Gary

Gary is a macOS shell that draws a bar, panels, overlays, and menus from plugins you write in TypeScript. Each plugin runs in its own JavaScriptCore context and reaches the system through capabilities such as battery, audio, Wi-Fi, and now playing.

Gary needs macOS 27.2 or later on Apple silicon.

## Install

Run the install script:

```sh
curl -fsSL https://raw.githubusercontent.com/sndrgrdn/gary/main/scripts/install.sh | sh
```

The script downloads the latest release and checks its checksum and signature. It installs `~/Applications/Gary.app`, links `~/.local/bin/gary`, starts Gary at login, and starts Gary now. To install a specific version, add `-s -- 0.2.0` after `sh`. You can run the script again at any time.

### Install with Homebrew

```sh
brew install --cask sndrgrdn/tap/gary
```

Homebrew installs `/Applications/Gary.app` and puts `gary` on your `PATH`. To start Gary at login and start it now, run:

```sh
gary login on
open -a Gary
```

### Install from source

You need Xcode with Swift 6.2, [`just`](https://github.com/casey/just), and a code-signing certificate in your keychain. Then run:

```sh
IDENTITY="<your certificate name>" just install
```

`IDENTITY` defaults to `Sander Local Signing`. `just install` does not turn on start at login. Run `gary login on` for that.

## First run

Grant the macOS permissions that your plugins need:

```sh
gary onboarding
```

The **Set up Gary** window lists each permission with an **Allow** button. Run `gary permissions` to see what Gary has.

Gary is signed with a local certificate and is not notarized. If macOS says that it cannot verify the developer, open **System Settings > Privacy & Security** and click **Open Anyway**. macOS keeps your permission grants across updates because every release uses the same certificate.

## Write plugins with an agent

Install the `gary` skill into Claude Code and into agents that read `~/.agents/skills`:

```sh
gary skill setup
```

The skill points the agent to `gary skill show`, which prints the plugin guide for the installed version. [`docs/plugins.md`](docs/plugins.md) covers the same ground for people.

## Install plugins

```sh
gary plugin install git:github.com/you/gary-plugins
```

`gary plugin install` takes `npm:<name>[@version]`, `git:<host>/<owner>/<repo>[@ref]`, a git URL, or a local folder. It records the package in `packages` in `~/.config/gary/shell.json` and enables its plugins. `gary plugin update` updates every package, and `gary plugin remove <source>` removes one. [`docs/plugins.md`](docs/plugins.md) has the details.

## Update

```sh
gary update
```

`gary update` prints the installed and latest versions, and installs the latest release if they differ. If you installed Gary with Homebrew, run `brew upgrade --cask gary` instead. `gary --version` prints the installed version.

## Uninstall

```sh
gary login off
gary skill remove
gary quit
rm -rf ~/Applications/Gary.app ~/.local/bin/gary
```

If you installed Gary with Homebrew, replace the last line with `brew uninstall --cask gary`.

To also delete your settings, plugins, plugin storage, log, and permission grants, run:

```sh
rm -rf ~/.config/gary ~/Library/Application\ Support/Gary ~/Library/Logs/gary.log
tccutil reset All com.sndrgrdn.gary
```

## License

Gary is released under the [MIT License](LICENSE). It includes [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) under the [BSD 3-Clause License](Vendor/mediaremote-adapter/LICENSE).
