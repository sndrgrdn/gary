# Develop Gary

Gary is a Swift package. The app and the `gary` command are one binary: `gary app` runs the shell, and every other verb talks to it over a Unix socket or works on `~/.config/gary`.

## Set up

You need:

- macOS 26 or later on Apple silicon.
- Xcode with Swift 6.2.
- Node.js and npm, for the TypeScript tooling. Run `npm ci` once.
- A code-signing certificate in your keychain, for `just install` and `just bundle`. macOS ties permission grants to it.
- [mise](https://mise.jdx.dev), which installs the versions of `just`, SwiftFormat, SwiftLint, ShellCheck, and outskirts that `mise.toml` pins. Run `mise install` once.

## Build and run

| Command        | Does                                                                                                  |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| `just build`   | Builds the debug binary with `swift build`.                                                           |
| `just run`     | Stops the running Gary, builds a debug `build/Gary.app`, and runs it in the foreground with its log.  |
| `just bundle`  | Builds a signed release `build/Gary.app`. Pass `--debug` for a debug build.                           |
| `just install` | Bundles Gary, installs it in `~/Applications/Gary.app`, links `~/.local/bin/gary`, and restarts Gary. |
| `just kill`    | Stops the running Gary.                                                                               |

Set `IDENTITY` to the name of your certificate for `just bundle` and `just install`. It defaults to `Developer ID Application: Sander Tuin (8U24BL7PPN)`, the certificate that signs releases. Install Gary in `~/Applications` with `just install` while you work on it, so that macOS keeps its permission grants across rebuilds.

## Check a change

CI runs these checks on every push and pull request:

| Command          | Checks                                                                                  |
| ---------------- | --------------------------------------------------------------------------------------- |
| `just lint`      | SwiftFormat, SwiftLint, ShellCheck, oxlint, and oxfmt. `just format` fixes what it can. |
| `just test`      | The Swift Testing suites in `Tests/`.                                                   |
| `just typecheck` | Every example, every built-in plugin, and `gary:effect` with `tsc`.                     |
| `just dead-code` | Unused Swift code, with outskirts, the maintained fork of Periphery.                    |
| `just anti-slop` | The repository's own Swift style rules, from `tools/anti-slop-swift`.                   |

CI also builds with warnings as errors: `swift build -Xswiftc -warnings-as-errors`.

## Repository layout

| Path                   | Holds                                                                                                            |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `Sources/gary/`        | The app and the command: the shell, plugin runtime, SwiftUI node views, capabilities, and the agent guide.       |
| `Sources/GaryCore/`    | The pure model: manifests, nodes, themes, `shell.json`, package sources, IPC messages, and parsers. Unit tested. |
| `Sources/GarySocket/`  | The Unix socket server and client for the command.                                                               |
| `Sources/GaryPrivate/` | Every private macOS symbol that Gary uses, resolved at run time, so a missing one turns off only its feature.    |
| `Sources/gary-effect/` | The TypeScript source of `gary:effect`.                                                                          |
| `Resources/`           | `Info.plist`, the icon, the built-in `theme.json`, the built-in plugins, and the vendored sucrase and Effect.    |
| `examples/`            | The example plugins that Gary.app bundles.                                                                       |
| `scripts/`             | Bundling, installing, releasing, vendoring, and benchmarks.                                                      |
| `Vendor/`              | [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), for now playing.                           |
| `tools/`               | The custom lint rules for TypeScript and Swift.                                                                  |
| `docs/research/`       | Research notes written while designing Gary.                                                                     |

## Change what plugins see

- The agent guide that `gary skill show` prints lives in `Sources/gary/SkillGuide.swift`, `SkillRequests.swift`, `SkillSections.swift`, and `SkillReference.swift`. Each capability's summary, example, and types live with the capability in `Sources/gary/Capabilities/`. Tests check that the guide covers every capability and that every example and recipe type-checks.
- An example's first paragraph in its `README.md` becomes its line in the guide. Keep it to what the example shows.
- After you change `Sources/gary-effect/` or the `effect` version in `package.json`, run `scripts/vendor-effect.sh`. To update sucrase, run `scripts/vendor-sucrase.sh`.
- Update this `docs/` folder and the [README](../README.md) when a change affects users.

## Measure performance

- `scripts/memory.sh` runs private Gary instances and reports memory and CPU per scenario. `scripts/memory.sh gate` measures memory and speed together with every plugin from gary-plugins loaded.
- `scripts/bench/` holds the render and engine benchmarks. [`BASELINE.md`](../scripts/bench/BASELINE.md) and [`RESULTS.md`](../scripts/bench/RESULTS.md) record past runs.
- `scripts/rhythm.sh` measures alignment and spacing in a screenshot, in points.

## Release

```sh
just release 0.4.0
```

Add each user-visible change to the `## Unreleased` section of `CHANGELOG.md` when it lands. Write for the people who use Gary or write plugins: what they can now do, what changed for them, and what they must change, under `### Upgrading` first. Leave out internal work such as refactors, tests, CI, and tooling.

`scripts/release.sh` needs a clean `main` that matches `origin/main`, the GitHub CLI, and a clone of [sndrgrdn/homebrew-tap](https://github.com/sndrgrdn/homebrew-tap) next to this repository, or at `$TAP`. It also needs the Developer ID Application certificate in the keychain and notarization credentials saved as the `GaryNotary` keychain profile, or the profile named by `$NOTARY_PROFILE`:

```sh
xcrun notarytool store-credentials GaryNotary --apple-id <Apple ID> --team-id 8U24BL7PPN
```

It renames `## Unreleased` to `## 0.4.0` under a new empty `## Unreleased`, then commits and pushes `Release 0.4.0`. Then it bundles and signs Gary, notarizes it with `scripts/notarize.sh`, which staples the ticket and checks that Gatekeeper accepts the app, zips it with a SHA-256 checksum, and tags and pushes the version. It creates the GitHub release with the `## 0.4.0` section as its notes, and updates and pushes the Homebrew cask. If a step fails, run the same command again. It reuses the `Release 0.4.0` commit.
