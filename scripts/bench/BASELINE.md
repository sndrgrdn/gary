# Render performance baseline

This file records what Gary's render pipeline costs before any optimization, what limits each scenario, and which changes could pay off. The numbers come from `scripts/bench/baseline.sh` on a release build of commit 97ece4f, which is `main` 85704e1 plus the `GARY_TRACE` stage timings. Later commits on this branch change only `scripts/bench/`.

## How the numbers were taken

- Machine: Apple M4 Pro, 14 cores (10 performance, 4 efficiency), 48 GB, macOS 27.2.1, built-in display at 120 Hz.
- Build: `scripts/bundle.sh` without `--debug`, which builds `-c release`.
- Driver: `baseline.sh` runs every case in a fresh Gary inside `/usr/bin/lockf -k /tmp/gary-live.lock`. It installs the bench plugins from `scripts/bench/plugins/`, launches `build/Gary.app`, waits 20 s, summons the panel, waits until a `gary call <id> stats` round trip is under 100 ms three times in a row, then measures for 15 s (60 s for S1). It quits and reopens `~/Applications/Gary.app` after every case.
- Order: each of the 5 runs does every case untraced, then the traced cases with `GARY_TRACE=1`, then two cases on a release build of `main` 85704e1 for the overhead check.
- Gary CPU, wakeups and footprint come from `proc_pid_rusage` (`meter.swift`). WindowServer CPU comes from `ps` CPU time. GPU is the system-wide `Device Utilization %` from `ioreg`, because `powermetrics` needs sudo.
- Render counts come from each bench plugin's `stats` method, timed by the plugin's own clock. Commits on screen and stage times come from the `commit` lines that `GARY_TRACE` writes. Two screenshots of the largest window, taken 0.5 s apart (1.1 s for S1), check that pixels changed.
- Profiles come from `render.py profile <case> 10 <out>`, which runs `sample` for 10 s in a separate run that is not reported. `profile.py` summarizes them. Sampling slows the process, so the profiles give the share of each code path, not the busy percentage.

## Noise and excluded runs

- Load average was 2.9 to 10.6 during the reported runs. `mediaanalysisd` used 220 to 360% CPU through the whole session. Another agent's `swift-test` used up to 60% in some runs. Neither can be stopped without sudo, so cases run interleaved and every run sees the same background.
- The display slept at 02:56 and the screen locked. Runs 3 to 5 ran with nothing composited. In those runs the S4 animations paused (S4 shader CPU 0.1% instead of 12%), WindowServer fell to about 1%, and S2-500 and S2-1000 CPU fell 8 to 10%. The report drops these runs. `render.py` now records the screen state, refuses to run while the screen is locked or asleep, and drops runs where it changed.
- For the first 10 to 15 s after Gary launches, `CATransaction.flush()` blocks for about 190 ms per commit. A 1000-node panel at 30 Hz then falls up to 7.7 s behind and catches up at 41 commits/s. A panel summoned 30 s after launch shows no stall on its first or second summon. The cause is not known. The driver waits 20 s after launch so that the stall stays out of the measured window.

So the columns below are:

- **Screen on**: runs 1 and 2, n=2. This is below the bench checklist's 5 runs. Run `RUNS=3 scripts/bench/baseline.sh` with the screen unlocked to reach 5.
- **All runs**: runs 1 to 5, n=5, only for metrics whose screen-on and screen-off values overlap.

## Baseline

Each value is the median, then the range in parentheses.

| Scenario                                     | Gary CPU %, screen on  | Gary CPU %, all runs | WindowServer CPU %, screen on | Work done                              |
| -------------------------------------------- | ---------------------- | -------------------- | ----------------------------- | -------------------------------------- |
| S1 idle bar, user bar plus a 1 Hz widget     | 0.4 (0.4 to 0.5)       | 0.5 (0.4 to 0.6)     | 6.0 (4.4 to 7.6)              | 1.0 ticks/s, 13 wakeups/s, 44 MB       |
| S2 busy panel, 100 nodes, 30 Hz              | 39.4 (39.2 to 39.7)    | 39.6 (39.2 to 39.9)  | 7.7 (6.7 to 8.7)              | 30.0 renders/s, 30.0 commits/s         |
| S2 busy panel, 500 nodes                     | 54.9 (51.3 to 58.6)    | screen-dependent     | 9.0 (8.7 to 9.3)              | 30.0 renders/s, 30.0 commits/s         |
| S2 busy panel, 1000 nodes                    | 105.9 (103.8 to 108.0) | screen-dependent     | 9.8 (9.5 to 10.1)             | 30.0 renders/s, 30.0 commits/s, 178 MB |
| S4 20 icons, no loop (control)               | 0.1 (0.0 to 0.1)       | 0.0 (0.0 to 0.1)     | 5.3 (5.1 to 5.6)              | no repaint, as expected                |
| S4 20 `loop` icons                           | 14.4 (13.6 to 15.2)    | screen-dependent     | 56.0 (54.1 to 58.0)           | 123 wakeups/s, repainted               |
| S4 1 animated `shader`                       | 12.1 (11.6 to 12.6)    | screen-dependent     | 43.9 (43.5 to 44.3)           | GPU 13.9% (10.1 to 17.8), repainted    |
| S5 bar widget at 30 Hz, 1 KB topic (control) | 9.2 (9.2 to 9.2)       | screen-dependent     | 13.6 (13.6 to 13.6)           | 31.0 renders/s                         |
| S5 bar widget at 30 Hz, 200 KB topic         | 42.5 (42.4 to 42.6)    | 42.6 (42.4 to 43.2)  | 13.0 (12.9 to 13.1)           | 31.1 renders/s, 1 publish/s            |

S3 measures a 1000-node panel from `gary summon` to its first commit. The CLI round trip ends after `CATransaction.flush()`, so it includes the commit to WindowServer but not the next display refresh.

| S3, all runs              | Summon to first commit, CLI | `since_ms` from the trace |
| ------------------------- | --------------------------- | ------------------------- |
| First summon after launch | 236 ms (230 to 240), n=5    | 224 ms (206 to 228), n=5  |
| Later summons             | 250 ms (218 to 256), n=15   | 218 ms (211 to 227), n=15 |

Every run settled, logged no `failed` line, and returned no harness error. In S2, renders, commits and the timer rate all equal 30.0/s, so every render reached the screen.

### Stage times

Traced runs, p50 in ms, median over all 5 runs. Plugin-thread stages match between screen-on and screen-off runs. Main-thread stages (`apply`, `layout`, `flush`) ran 5 to 10% faster with the screen off.

| Stage                                              | S2 100 | S2 500 | S2 1000 | S3 later summons | S5 200 KB |
| -------------------------------------------------- | ------ | ------ | ------- | ---------------- | --------- |
| `encode` (state to JSON)                           | 0.24   | 0.10   | 0.09    | 0.29             | 12.19     |
| `js_parse` + `render` + `stringify`                | 0.22   | 0.12   | 0.20    | 1.46             | 0.52      |
| `swift_parse` (`JSON.parse`)                       | 2.36   | 4.21   | 7.79    | 22.57            | 0.01      |
| `node_parse` (`Node.parse`, `resolvingPaths`)      | 0.55   | 0.98   | 1.93    | 5.06             | 0.00      |
| `compare`                                          | 0.05   | 0.07   | 0.14    | none             | 0.00      |
| `apply` (main thread, `MountedTree.root`)          | 0.39   | 0.13   | 0.21    | 166.28           | 0.01      |
| `layout` (`layoutSubtreeIfNeeded`, SwiftUI update) | 8.99   | 9.84   | 21.43   | 1.92             | 0.18      |
| `flush` (`CATransaction.flush`)                    | 0.42   | 0.26   | 0.36    | 13.15            | 0.10      |
| `since` (trigger to flushed commit)                | 13.9   | 15.8   | 32.3    | 218.1            | 13.1      |

The stage sum explains Gary's CPU. For example, S2 1000 spends 32.1 ms of stages per frame. At 30 frames/s that is 96% of a core, against 93 to 108% measured. In S2 100, 13.2 ms per frame is 40%, against 39.6% measured.

The shares below divide a stage's time by the per-frame CPU, which is the measured CPU divided by renders per second. That is 13.2 ms for S2 100, 18.3 ms for S2 500, 35.3 ms for S2 1000, and 13.7 ms for S5 200 KB.

## Limiters

| Scenario  | Limiter                                                                                                                                                                                                                                                                 | Evidence                                                                                                                                                                                                                                                                                                   |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1        | Nothing. Gary is idle apart from timer wakeups.                                                                                                                                                                                                                         | 0.9% of a core busy in the profile, spread over JavaScriptCore GC scavenging and text layout.                                                                                                                                                                                                              |
| S2        | The main thread, in the SwiftUI update. `layout` is 54 to 68% of each frame. At 1000 nodes, commits keep the main thread 66% busy at 30 Hz, and display-cycle updates add about 9%. Second is Foundation's `JSONDecoder` on the plugin thread, 18 to 23% of each frame. | Main thread: `ViewGraphRootValueUpdater.render`, then `AG::Subgraph::update`, with about 37% in stack layout, about 30% in attribute and body updates, and 10% self time in `memmove`. Plugin thread: 72% `JSONDecoder` decoding the `JSON` enum through `Codable`, 13% `NodeReader`, 7% `resolvingPaths`. |
| S3        | The main thread, building the SwiftUI graph on the first mount. `apply` is 76% of `since`. `JSONDecoder` adds 10% and `flush` adds 6%.                                                                                                                                  | 71% of main-thread samples are under `Shell.mount`, mostly `ForEach` node creation and modifier `_makeView` calls. Tearing down the hidden panel takes another 18% in `AG::Graph::invalidate_subgraphs`.                                                                                                   |
| S4 loops  | The SwiftUI update for each display frame, driven by `TimelineView(.animation)` in `LoopEffect`, plus WindowServer compositing at 120 Hz.                                                                                                                               | Main thread is under `NSDisplayCycleObserverInvoke`, then `NSHostingView.layout`, then `ViewGraphRootValueUpdater.render`. WindowServer uses 56% against 5.3% for the static control.                                                                                                                      |
| S4 shader | `MTKView` drawing at the display's 120 Hz. The app's share is GPU command submission and drawable waits. WindowServer compositing costs 3.6 times Gary's CPU.                                                                                                           | Top self time is `iokit_user_client_trap`, and the main thread waits in `MetalCanvas.Coordinator.draw` for the next drawable.                                                                                                                                                                              |
| S5 200 KB | `stateText`, which re-encodes the unchanged 200 KB topic value on all 31 renders per second. `encode` is 93% of `since`.                                                                                                                                                | 85% of plugin-thread samples are in `JSONEncoder.encode`.                                                                                                                                                                                                                                                  |

## Ranked hypotheses

Each expected gain is the most the change can save, as a share of the scenario's per-frame CPU. It is the measured cost of the stage the change removes, so the real gain is lower. None of these were tested here.

| Rank | Change                                                                                                                       | Where it pays                                                                               | Expected gain                                                                                                                                                                                         | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1    | Avoid the full `stateText` per call. Encode each topic value once per publish and reuse it.                                  | Plugins that subscribe to large topics.                                                     | S5 200 KB: up to 89% (12.2 of 13.7 ms per render), so 42.5% CPU could fall to about 5%. S2: under 2%.                                                                                                 | The JS `JSON.parse` of the state (0.5 ms) stays unless the state also crosses differently.                                                                                                                                                                                                                                                                                                                                                                                                       |
| 2    | Narrow the SwiftUI update. Make `NodeView` equatable, cut the modifier chain per node, and give stacks sizes they can cache. | Every panel that updates often. This is the only lever on main-thread throughput and on S3. | S2: up to 54 to 68% of each frame. S3: up to 76% of first-render time.                                                                                                                                | A diagnostic build, not committed, counted `NodeView.body` calls per commit: 20 at 100 nodes and 60 at 1000 nodes. Both counts equal the root plus every row plus every cell of the changed row. One changed text does not re-evaluate every `NodeView`. The cost that grows with N is stack layout over the whole tree. `layout` grows from 9.8 ms at 500 nodes to 21.4 ms at 1000 nodes. That is where the 1000-node column overflows the 900 pt panel, so overflow could be part of the jump. |
| 3    | Cheaper JSON crossing on the Swift side. Replace `JSONDecoder` with `JSONSerialization` or a `JSValue` walk.                 | Large trees. Runs off the main thread, so it cuts CPU and latency, not throughput.          | S2 1000: about 16% (5.8 of 35.3 ms per frame) and about 18% of `since`. S3: about 8%.                                                                                                                 | `crossing.swift` on the 1000-node tree: `JSONDecoder` 9.2 ms, `JSONSerialization` plus conversion 2.3 ms, `JSValue.toObject` plus conversion 2.8 ms.                                                                                                                                                                                                                                                                                                                                             |
| 4    | Send only changed subtrees, with a keyed diff or patch protocol.                                                             | Large trees with small changes.                                                             | S2 1000: up to 28% (stringify, parse, node parse and compare, 9.9 ms). After rank 3, about 12%. No main-thread gain unless paired with rank 2.                                                        | It overlaps rank 3, which is simpler and takes most of the same cost.                                                                                                                                                                                                                                                                                                                                                                                                                            |
| 5    | Cap animation frame rate, or move `loop` to Core Animation.                                                                  | Panels with `loop` nodes or animated shaders.                                               | S4 loops: Core Animation could remove most of Gary's 14.4% (guess). A 60 Hz cap would halve Gary's and WindowServer's cost (inferred). S4 shader: a 60 Hz cap would halve 12.1% and 43.9% (inferred). | `MetalCanvas` sets `preferredFramesPerSecond` to the screen maximum.                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 6    | Coalesce deliveries to the main thread, and apply only the newest output per slot.                                           | Any time the main thread is slower than the plugin.                                         | No CPU gain at steady state. It bounds latency to one frame, against the 7.7 s backlog seen after launch.                                                                                             | This candidate is new. The post-launch stall shows that the main queue applies every stale output in order.                                                                                                                                                                                                                                                                                                                                                                                      |
| 7    | Cheaper `Node` equality.                                                                                                     | None measured.                                                                              | `compare` is 0.4% of each frame, and `apply`, which holds the mount equality, is under 1.2%.                                                                                                          | Not worth doing.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 8    | Skip rendering when the state did not change.                                                                                | None measured.                                                                              | 0 in these scenarios. Unchanged renders were 0.0 to 0.1/s.                                                                                                                                            | Timers change plugin state that Gary cannot see, so Gary must render to know. The `compare` step already skips main-thread work for unchanged trees. Measure the unchanged share on real bars with `GARY_TRACE` before building this.                                                                                                                                                                                                                                                            |

## What bounds the node cap

`Node.maxNodes` is 1000. In order of how soon each limit is reached:

1. **SwiftUI on the main thread.** At 1000 nodes a 30 Hz panel needs 22 ms of main-thread time per commit, 66% of the 33 ms budget, plus about 3 ms of display-cycle updates. The first mount takes 166 ms. If cost grows at the 500 to 1000 node slope (about 23 µs per node per update), a 30 Hz panel saturates the main thread at 1,400 to 1,500 nodes. A 2000-node first mount would spend about 330 ms in `apply` alone (inferred).
2. **Parsing on the plugin thread.** `JSON.parse` and `Node.parse` cost about 9.7 µs per node. A 30 Hz panel saturates the plugin queue near 3,400 nodes. With `JSONSerialization` this limit moves to about 8,500 nodes (inferred from `crossing.swift`).
3. **The 100 ms watchdog.** JavaScript spends 0.2 ms on a 1000-node render (state parse, `render`, `JSON.stringify`). The watchdog allows about 500 times more.

So SwiftUI bounds the cap. Raising it is safe for panels that change rarely. It is not safe for panels that update at 30 Hz until rank 2 lands.

## Inconclusive

- Screen-dependent rows have n=2.
- Instrumentation overhead with `GARY_TRACE` off: S2 100 shows no measurable difference against `main` (39.6% against 39.4%, ranges overlap, n=5 each). In S5 1 KB with the screen off, the ranges overlap (7.8% against 7.9%, n=3 and n=4). With the screen on, this branch measured 9.2% (n=2) against 8.1% for `main` (n=1), which is too few runs to decide. In the code, every timing call returns early when `tracing` is false.
- GPU % is system-wide, not Gary's alone.
- The post-launch flush stall has no known cause.
- `swift_parse` takes 22.6 ms for the 1000-node tree in S3 but 7.8 ms in S2. Cold caches or a CPU still ramping its clock could explain it. Nothing here tests either.
- `layout` covers the SwiftUI update run by `layoutSubtreeIfNeeded`. Display-cycle updates outside `commitFrame` are not attributed. They are about 3 ms per frame at 1000 nodes, the gap between the stage sum and the measured CPU.
- No scenario goes past 1000 nodes, because the cap rejects bigger trees. The cap estimates above extrapolate from 100, 500 and 1000 nodes.

## Rerun

Run these commands from the repository root with the screen unlocked. They quit and relaunch the user's Gary.

    scripts/bundle.sh
    RUNS=5 scripts/bench/baseline.sh
    python3 scripts/bench/render.py report tmp/bench/baseline-<stamp>.jsonl

Set `BASE_APP` to a release build of another commit to compare against it. It defaults to `tmp/base/build/Gary.app`. To profile one case, run:

    /usr/bin/lockf -k /tmp/gary-live.lock python3 scripts/bench/render.py profile s2-busy-1000 10 tmp/bench/s2.txt
    python3 scripts/bench/profile.py tmp/bench/s2.txt

To time the JSON crossing alternatives, run:

    swiftc -O -o tmp/bin/crossing scripts/bench/crossing.swift
    tmp/bin/crossing scripts/bench/plugins 1000
