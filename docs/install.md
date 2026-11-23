# Install Gary

Gary needs macOS 26 or later on Apple silicon. Install it with the install script, with Homebrew, or from source. Each method puts the `gary` command on your `PATH`.

## Install with the script

```sh
curl -fsSL https://raw.githubusercontent.com/sndrgrdn/gary/main/scripts/install.sh | sh
```

The script downloads the latest release from GitHub and checks its checksum and its code signature. Then it does the following:

1. It installs `~/Applications/Gary.app`.
2. It links `~/.local/bin/gary` to the `gary` command inside the app.
3. It turns on start at login with `gary login on`.
4. It starts Gary and waits until `gary ping` answers.

To install a specific version, add `-s -- <version>` after `sh`, such as `sh -s -- 0.3.1`. You can run the script again at any time. When that version is already installed, the script skips the download. If `~/.local/bin` is not on your `PATH`, the script says so.

## Install with Homebrew

```sh
brew install --cask sndrgrdn/tap/gary
```

Homebrew installs `/Applications/Gary.app` and puts `gary` on your `PATH`. Homebrew does not start Gary. To start Gary at login and start it now, run:

```sh
gary login on
open -a Gary
```

## Build from source

You need Xcode with Swift 6.2, [`just`](https://github.com/casey/just), and a code-signing certificate in your keychain. macOS ties permission grants to the certificate that signs the app, so a stable certificate keeps your grants across rebuilds. Build and install with:

```sh
IDENTITY="<your certificate name>" just install
```

`just install` builds a release bundle, copies it to `~/Applications/Gary.app`, links `~/.local/bin/gary`, and restarts Gary if it was running. It does not turn on start at login, so run `gary login on` for that. `IDENTITY` defaults to `Sander Local Signing`. [Develop Gary](development.md) covers the other build commands.

## First run

On first launch, Gary shows a bar with the built-in clock and battery widgets at the top of each display, and opens the **Set up Gary** window. The window lists each macOS permission that your enabled plugins need, with an **Allow** button for each. Open it again at any time:

```sh
gary onboarding
```

`gary permissions` prints the same list in the terminal. macOS grants each permission to Gary itself, not to your terminal. [Capabilities and permissions](capabilities.md#permissions) lists which capability needs which permission.

Gary is signed with a local certificate and is not notarized. If macOS says that it cannot verify the developer, open **System Settings > Privacy & Security** and click **Open Anyway**. Every release uses the same certificate, so macOS keeps your permission grants across updates.

## Teach your coding agent

```sh
gary skill setup
```

The command installs the `gary` skill into `~/.claude/skills` for Claude Code, and into `~/.agents/skills` for Codex, OpenCode, and pi. It skips an agent whose home folder does not exist. The skill tells the agent to run `gary skill show`, which prints the plugin guide for the installed version. `gary skill status` shows where the skill is installed, and `gary skill remove` removes it. The [README](../README.md#for-agents) has a prompt that has an agent set up Gary for you.

## Update

```sh
gary update
```

`gary update` prints the installed and the latest version, and runs the install script when they differ. If you installed Gary with Homebrew, run `brew upgrade --cask gary` instead. `gary --version` prints the installed version.

## Uninstall

Stop Gary, turn off start at login, and remove the skill, the app, and the command:

```sh
gary login off
gary skill remove
gary quit
rm -rf ~/Applications/Gary.app ~/.local/bin/gary
```

`gary quit` gives back the menu bar, the Dock, and Caps Lock if plugins changed them. If you installed Gary with Homebrew, replace the last line with `brew uninstall --cask gary`.

To also delete your settings, plugins, plugin storage, caches, log, and permission grants, run:

```sh
rm -rf ~/.config/gary ~/Library/Application\ Support/Gary ~/Library/Caches/Gary ~/Library/Logs/gary.log
tccutil reset All com.sndrgrdn.gary
```
