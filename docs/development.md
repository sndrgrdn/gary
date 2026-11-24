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

| Command         | Does                                                                                                  |
| --------------- | ----------------------------------------------------------------------------------------------------- |
| `just build`    | Builds the debug binary with `swift build`.                                                           |
| `just run`      | Stops the running Gary, builds a debug `build/Gary.app`, and runs it in the foreground with its log.  |
| `just bundle`   | Builds a signed release `build/Gary.app`. Pass `--debug` for a debug build.                           |
| `just install`  | Bundles Gary, installs it in `~/Applications/Gary.app`, links `~/.local/bin/gary`, and restarts Gary. |
| `just kill`     | Stops the running Gary.                                                                               |
| `just isolated` | Builds a debug `build/Gary.app` and runs it next to your Gary, with its own home. See below.          |

Set `IDENTITY` to the name of your certificate for `just bundle` and `just install`. It defaults to `Sander Local Signing`. Install Gary in `~/Applications` with `just install` while you work on it, so that macOS keeps its permission grants across rebuilds.

## Run an isolated Gary

`just isolated [home]` runs a second Gary next to the one you use, to test plugins, reproduce bugs, and measure, without touching your config or your running Gary. `home` defaults to `tmp/isolated`. The first run seeds it with a `shell.json` that puts the built-in battery and clock in the bar, and marks onboarding as seen. Put plugins in `<home>/.config/gary/plugins`. Stop it with Control-C.

Two environment variables isolate any Gary, and `just isolated` sets both:

| Variable           | Moves                                                                                                                                                       |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GARY_HOME`        | Everything Gary keeps under your home: `.config/gary`, `Library/Application Support/Gary`, `Library/Caches`, `Library/Logs/gary.log`, and installed skills. |
| `GARY_RUNTIME_DIR` | The lock, the socket, the supervisor lock, and the temporary files of capabilities. It defaults to `$TMPDIR`.                                               |

The `gary` command reaches the Gary whose socket is in `GARY_RUNTIME_DIR`. Use the one in the build, since an installed Gary may predate it:

```sh
GARY_RUNTIME_DIR="$PWD/tmp/isolated/run" build/Gary.app/Contents/MacOS/gary listPlugins
```

An isolated Gary leaves global hotkeys, the Hyper key, media keys, the Dock, and the menu bar to your Gary. It keeps the hotkeys its plugins declare for `gary key`, and `host.hyperkey`, `host.dock`, and `host.menubar.hide` throw. Set `GARY_ISOLATED_SYSTEM=1` to let it take them. The paths a plugin passes, such as `~/Pictures/a.png`, still resolve against your real home, as do the macOS databases Gary reads for Focus and notifications, `~/Applications`, and crash reports. Code in `Sources/` resolves the home and temporary folders only through `Paths`, and a SwiftLint rule enforces it.

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
| `tools/`               | The custom lint rules for TypeScript and Swift, and frame-bench.                                                 |
| `docs/research/`       | Research notes written while designing Gary.                                                                     |

## Change what plugins see

- The agent guide that `gary skill show` prints lives in `Sources/gary/SkillGuide.swift`, `SkillRequests.swift`, `SkillSections.swift`, and `SkillReference.swift`. Each capability's summary, example, and types live with the capability in `Sources/gary/Capabilities/`. Tests check that the guide covers every capability and that every example and recipe type-checks.
- An example's first paragraph in its `README.md` becomes its line in the guide. Keep it to what the example shows.
- After you change `Sources/gary-effect/` or the `effect` version in `package.json`, run `scripts/vendor-effect.sh`. To update sucrase, run `scripts/vendor-sucrase.sh`.
- Update this `docs/` folder and the [README](../README.md) when a change affects users.

## Measure performance

- `scripts/memory.sh` runs private Gary instances and reports memory and CPU per scenario. `scripts/memory.sh gate` measures memory and speed together with every plugin from gary-plugins loaded.
- `scripts/bench/` holds the render and engine benchmarks. [`BASELINE.md`](../scripts/bench/BASELINE.md) and [`RESULTS.md`](../scripts/bench/RESULTS.md) record past runs.
- `tools/frame-bench/frame-bench.py` runs a frame-pacing scenario several times against two or more bundled builds, alternating them, and reports the median and spread of `gary frames` hitch time per build. Pass `--instruments` to record the first run of each build with Instruments' Animation Hitches.
- `scripts/rhythm.sh` measures alignment and spacing in a screenshot, in points.
