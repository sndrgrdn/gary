# Gary

Gary is a macOS shell that draws a bar, panels, overlays, and menus from plugins you write in TypeScript. Each plugin runs in its own JavaScriptCore context and reaches the system through capabilities such as battery, audio, Wi-Fi, and now playing.

Gary needs macOS 27.2 or later on Apple silicon.

## Install

You need the [GitHub CLI](https://cli.github.com), logged in with `gh auth login`, and read access to this private repository.

Run the install script:

```sh
gh api repos/sndrgrdn/gary/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | sh
```

The script downloads the latest release and checks its checksum and signature. It installs `~/Applications/Gary.app`, links `~/.local/bin/gary`, starts Gary at login, and starts Gary now. To install a specific version, add `-s -- 0.1.0` after `sh`. You can run the script again at any time.

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

## Update

```sh
gary update
```

`gary update` prints the installed and latest versions, and installs the latest release if they differ. `gary --version` prints the installed version.

## Uninstall

```sh
gary login off
gary skill remove
gary quit
rm -rf ~/Applications/Gary.app ~/.local/bin/gary
```

To also delete your settings, plugins, plugin storage, log, and permission grants, run:

```sh
rm -rf ~/.config/gary ~/Library/Application\ Support/Gary ~/Library/Logs/gary.log
tccutil reset All com.sndrgrdn.gary
```

## License

Gary is released under the [MIT License](LICENSE). It includes [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) under the [BSD 3-Clause License](Vendor/mediaremote-adapter/LICENSE).
