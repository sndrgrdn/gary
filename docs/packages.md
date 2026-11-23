# Packages

A package is a folder of plugins that you install from git, npm, or a local folder. If the folder's root has a `manifest.json`, the package is one plugin. Otherwise each folder directly inside it that has a `manifest.json` is a plugin.

## Install a package

```sh
gary plugin install git:github.com/sndrgrdn/gary-plugins
gary plugin install git:github.com/you/gary-plugins@v1.0.0
gary plugin install https://github.com/you/gary-plugins
gary plugin install npm:gary-weather@1.2.0
gary plugin install ~/src/gary-plugins
```

`gary plugin install` fetches the package and validates its plugins without running any of them. It lists the capabilities of each plugin with their macOS permissions. Then it adds the source to `packages` in `~/.config/gary/shell.json` and enables each plugin. A bar widget goes to the end of the bar section that its manifest's `bar` field names, `right` by default. A plugin that `shell.json` already places or disables keeps that setting.

Plugins run with your user's rights, and `host.exec` runs any command. Read a package from someone else before you install it.

## Where packages live

Gary keeps git and npm packages in `~/Library/Application Support/Gary/packages`. It clones git packages with the system `git`. It downloads npm packages from the registry without Node.js, and checks each download against the registry's sha512 integrity.

A local folder loads in place. Gary reloads its plugins when you save a file, as it does for `~/.config/gary/plugins`. When Gary starts, it installs each package in `shell.json` that is missing. If that fails, for example offline, Gary logs the failure, skips the package, and tries again on the next start.

A source identifies its package: npm by name, git by repository without the ref, and a local folder by its absolute path. So `git:github.com/you/gary-plugins@v2` replaces `git:github.com/you/gary-plugins`, and one package never loads twice. When two plugins share an id, the first one wins, in this order: built-in plugins, then `~/.config/gary/plugins`, then packages in the order that `shell.json` lists them.

## Manage packages and plugins

| Command                                               | Does                                                                                                                                                                          |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gary plugin list`                                    | Lists plugins with their version, whether `shell.json` enables them, their source, and whether the source is pinned.                                                          |
| `gary plugin enable <id>`, `gary plugin disable <id>` | Turns a plugin on or off in `shell.json`. An enabled bar widget goes to the bar section that its manifest names.                                                              |
| `gary plugin update [<source>]`                       | Updates every package, or one, and prints the old and new version or commit. An exact npm version, a git tag, or a commit stays put. A branch, or no ref, follows the remote. |
| `gary plugin remove <source\|id>`                     | Removes a package and drops its plugins from `shell.json`, or moves a plugin in `~/.config/gary/plugins` to the Trash. Plugin settings stay.                                  |

## Publish a package

1. Put each plugin in its own folder at the root of a repository, or put one plugin at the root.
2. Give each plugin a `README.md` that says what it shows, which settings it reads, and which permissions it needs.
3. Commit `manifest.json`, the entry files, `topic.ts`, and any files that the plugin reads. Leave out `node_modules`. `gary.d.ts` and `manifest.schema.json` are optional, because `gary plugin types` writes them.
4. Push the repository to a git host, or publish it to npm. Tag releases so that users can pin a version, such as `git:github.com/you/gary-plugins@v1.0.0`.

A plugin that subscribes to another plugin's topic types it from the publisher's `topic.ts`, when `gary plugin types` finds the publisher in a sibling folder, in `~/.config/gary/plugins`, or in a package in `shell.json`. So keep plugins that share topics in one package.

[sndrgrdn/gary-plugins](https://github.com/sndrgrdn/gary-plugins) is a package of about twenty plugins that you can read as a model.

## Work on a package in place

To edit a package that you also use, install your clone as a local folder:

```sh
git clone https://github.com/you/gary-plugins.git ~/src/gary-plugins
gary plugin install ~/src/gary-plugins
```

Gary loads the clone in place and reloads a plugin each time you save one of its files. To add a plugin, create a folder with a `manifest.json` in the clone, and enable it with `gary plugin enable <id>`.
