# Render performance results

This file records what each optimization unit changed, measured against the build before it. `BASELINE.md` holds the starting numbers and the limiter of each scenario. Units 0 to 5 ran on 22 November 2026 between 03:50 and 06:00 while the display was asleep, so every live number here was taken with nothing composited.

## How the numbers were taken

- Machine and build as in `BASELINE.md`: Apple M4 Pro, release builds from `scripts/bundle.sh`. Load average was 1.5 to 3.7 during the live runs.
- Live cases run only if `render.py` lists them in `DARK_OK`: `s2-busy-100` and `s5-large`, which `BASELINE.md` shows give the same numbers with the screen on or off, and `s6-launch-1000` (see unit 4). Pass `--dark-ok` to run them with the screen asleep.
- `ab.sh` rotates the builds in `APPS` through each case, so with A, B and C the runs go A B C, B C A, C A B. Every build sees the same drift and background load.
- `meter.swift` now also reads instructions, cycles, the share of cycles on performance cores, and energy from `proc_pid_rusage`. CPU time alone misleads here. When a change removes work, macOS moves the plugin threads to efficiency cores at a lower clock, so the remaining work takes longer and CPU % barely moves. In S2 100, CPU stayed at 39 to 40% while instructions fell by a quarter and energy by almost half. The tables report all four.
- `tree.sh` runs the in-process SwiftUI harness (`Tests/GaryTests/TreeViewBench.swift`), described under unit 3. `crossing.swift` times the JSON crossing with whichever `JSON.swift` it is compiled against.

Each value is the median, then the range. `n` is the run count per build.

## Unit 0: rebase onto `main` 780446a

The 11 conflicts in 4 files merged the stage timings with `main`'s named surfaces. Commit lines now carry `surface=`, and `surfaces` is timed like `render`. Moving the host setup into `PluginRuntime+Host.swift` keeps `PluginRuntime.swift` under the lint limit.

The rebased build gives the baseline's numbers, so the instrumentation still costs nothing measurable:

| Case      | `BASELINE.md`, all runs   | Rebased build 8a11dbb, screen asleep |
| --------- | ------------------------- | ------------------------------------ |
| S2 100    | 39.6% (39.2 to 39.9), n=5 | 39.4% (39.3 to 40.1), n=5            |
| S5 200 KB | 42.6% (42.4 to 43.2), n=5 | 43.3% (42.7 to 43.4), n=5            |

## Unit 1: cache the state text

`StateText` keeps the encoded JSON of every subscribed topic, the settings and the theme. A publish re-encodes one topic. A render joins the cached pieces and encodes only `display` and `surface`. `onTopic` reuses the topic's text too.

| S5 200 KB, n=5 each | Before (8a11dbb)        | After (dd02088)         | Change |
| ------------------- | ----------------------- | ----------------------- | ------ |
| Gary CPU            | 43.1% (42.0 to 43.3)    | 20.6% (20.3 to 20.8)    | −52%   |
| Instructions        | 6686 M/s (6679 to 6696) | 1099 M/s (1096 to 1102) | −84%   |
| Cycles              | 1214 M/s (1205 to 1217) | 309 M/s (304 to 316)    | −75%   |
| Cycles on P-cores   | 99.9%                   | 38.9%                   |        |
| Energy              | 1161 mW (1144 to 1194)  | 105 mW (102 to 110)     | −91%   |

S2 100 shows no measurable difference: 2159 against 2131 M instructions/s, 104 against 103 mW. Renders per second stayed at 31.1 in S5 and 30.0 in S2, and the widget showed the publish count, so the same work ran.

Limiter after the change, from a 10 s profile: the feed plugin's `JSONDecoder` on each 200 KB publish (the biggest thread, 13% of a core under sampling), the sink's `JSONEncoder` on each received topic, and JavaScriptCore's `JSON.parse` of the 200 KB state on every render (60% of the sink thread).

## Unit 2: cheaper JSON crossing

`JSON.parse` now runs a byte scanner (`JSONText.swift`) with an explicit container stack, and `JSON.text` writes directly. `prettyText` still uses `JSONEncoder`, so `JSON` is `Encodable` and no longer `Decodable`. A differential fuzz of 200,000 random values and their mutations against the old `JSONDecoder` path found identical `text` output and parse results with three exceptions, all where the old path was wrong: it rejected `0e1`, accepted a NUL byte next to a number, and accepted invalid text in the value of a duplicate key. Kept from the old path: sorted keys, unescaped slashes, `1` rather than `1.0`, `-0`, the exponent forms of `Double.description`, a leading byte order mark, trailing commas, the first of duplicate keys, the 512-level depth limit, and rejection of out-of-range numbers. Errors are still `JSON.ParseError` starting with `invalid JSON:`, now with the reason and byte offset.

Microbench, `crossing.swift` on the 1000-node tree and the 200 KB state, n=5 each, alternated:

| Step                     | `JSONDecoder` and `JSONEncoder` | Scanner and writer     |
| ------------------------ | ------------------------------- | ---------------------- |
| Parse the 1000-node tree | 7.80 ms (7.74 to 7.83)          | 0.70 ms (0.69 to 0.99) |
| Parse the 200 KB state   | 26.3 ms (26.1 to 26.6)          | 2.05 ms (2.01 to 2.08) |
| Encode the 200 KB state  | 6.97 ms (6.88 to 7.00)          | 1.81 ms (1.80 to 1.81) |

`JSONSerialization` plus conversion takes 2.07 ms for the tree, so the scanner is three times faster than the brief's fallback.

Live, n=5 each:

| Case and metric        | Before (dd02088)          | After (19877b1)         | Change |
| ---------------------- | ------------------------- | ----------------------- | ------ |
| S2 100 instructions    | 2131 M/s (2123 to 2133)   | 1594 M/s (1591 to 1599) | −25%   |
| S2 100 energy          | 102.8 mW (100.2 to 116.2) | 57.7 mW (57.5 to 58.8)  | −44%   |
| S2 100 CPU             | 39.3% (38.8 to 39.6)      | 39.9% (39.8 to 39.9)    | none   |
| S5 200 KB instructions | 1099 M/s (1096 to 1102)   | 467 M/s (464 to 470)    | −58%   |
| S5 200 KB energy       | 105 mW (102 to 110)       | 12.8 mW (12.8 to 13.2)  | −88%   |
| S5 200 KB CPU          | 20.6% (20.3 to 20.8)      | 16.1% (15.9 to 16.2)    | −22%   |

Traced, n=3, against the rebased base build: `swift_parse` in S2 100 fell from 2.93 to 0.36 ms per frame, and `encode` in S5 from 11.95 to 0.11 ms. Over units 1 and 2, S5 fell from 1214 to 180 M cycles/s. On a P-core at about 4 GHz that would be about 4.5% of a core (inferred), which meets the brief's target of about 5%. The CPU time stays at 16% only because the remaining work runs entirely on efficiency cores at a low clock.

Limiters after the change. S2 100 is bound by the main thread's SwiftUI update, `layout` at 8 to 10 ms of a 13 ms frame. S5 is bound by JavaScriptCore parsing the 200 KB state on each render. Removing that parse means sharing parsed topic values between renders. A render that mutates its state, such as `state.feed.items.reverse()`, would then see its own mutation on the next render, so this was not done.

## Unit 3: narrow the SwiftUI update

### The harness

`TreeViewBench` builds the `bench.busy` tree in Swift, hosts it in a `SurfaceWindow` placed as a 1200 × 900 panel, and applies 180 trees in which one text changes. It times, per frame, the mount update with `place` (`apply`), `layoutSubtreeIfNeeded` plus `displayIfNeeded` (`layout`), and `CATransaction.flush` (`flush`), and reports p50 and p95 over the last 150 frames. It also times the first mount and the JSON and node parse of each tree. Trees are built row by row, so the harness passes the node cap. It runs only when `GARY_TREE_BENCH` lists node counts.

    scripts/bench/tree.sh build <name>         # release build of the test bundle, copied to tmp/harness/<name>
    RUNS=5 SIZES=100,500,1000,2000 scripts/bench/tree.sh <name> <name>...

How it tracks the screen-on numbers in `BASELINE.md`, with the same SwiftUI code (unit 2 build 19877b1, n=5):

| Nodes | Screen-on `layout`, n=2 | Harness `layout` | Harness as a share |
| ----- | ----------------------- | ---------------- | ------------------ |
| 100   | 8.99 ms                 | 4.37 ms          | 49%                |
| 500   | 9.84 ms                 | 7.81 ms          | 79%                |
| 1000  | 21.43 ms                | 16.05 ms         | 75%                |

From 500 to 1000 nodes the harness grows 2.06 times against 2.18 times live, or 16.5 µs per node against 23.2 µs. Its first mount at 1000 nodes takes 160 ms against 166 ms of `apply` in S3. So the harness tracks the growth with node count closely and reads 20 to 25% low at 500 and 1000 nodes. At 100 nodes it reads half, because the live main thread then runs on efficiency cores at a low clock while the harness loop keeps a core busy. It does not include the display-cycle updates that run between commits with the screen on, about 3 ms per frame at 1000 nodes. Its profile matches the live one: stack layout, `NodeView.body`, and AttributeGraph updates.

### Candidates

Each row is frame p50 at 1000 nodes, n=5 per variant, alternated.

| Candidate                                                                              | Before    | After    | Kept           |
| -------------------------------------------------------------------------------------- | --------- | -------- | -------------- |
| `NodeView: Equatable` with `.equatable()` on children                                  | 16.68 ms  | 44.09 ms | no             |
| Same, comparing only the node                                                          | 16.82 ms  | 44.61 ms | no             |
| Skip both frames and the padding when they do nothing                                  | 16.76 ms  | 9.73 ms  | no, superseded |
| Skip only the padding when it is zero                                                  | 16.71 ms  | 15.12 ms | no             |
| Skip both frames when no width, height or minWidth is set                              | 16.71 ms  | 9.19 ms  | no, superseded |
| Skip only `.frame(minWidth:)` when there is no minWidth                                | 16.66 ms  | 9.18 ms  | yes            |
| Skip the identity visual effects (scale, rotation, blur, opacity, blend, loop, offset) | 9.20 ms   | 7.83 ms  | yes            |
| Pass `nil` to `.transaction(value:)` when the node has no animation                    | 7.86 ms   | 7.25 ms  | yes            |
| A custom `Layout` for row and column                                                   | not built |          |                |

The whole gain of skipping frames came from the empty `.frame(minWidth: nil, alignment:)`, a flexible frame. The profile before showed its alignment queries walking every row's subtree (inferred from `_FlexFrameLayout` under `explicitAlignment`). The fixed frame stays, so no node changes structure when its width changes. Making `NodeView` equatable tripled the update time, so it was dropped without further study. After the kept changes the profile is mostly AttributeGraph updates and view value comparison, and stack layout's alignment queries are under 5% of main-thread samples, so a custom `Layout` had no measured cost to remove.

The effects are skipped only when the node sets none of them, has no animation, and has no hovered or pressed style. So effects that change on hover or animate keep a stable structure.

### Result

Harness, unit 2 build against 283472c, n=5 each:

| Nodes | Frame p50 before          | Frame p50 after           | Change | First mount before | After   |
| ----- | ------------------------- | ------------------------- | ------ | ------------------ | ------- |
| 100   | 5.21 ms (5.08 to 5.24)    | 4.70 ms (3.71 to 4.80)    | −10%   | 41.3 ms            | 49.8 ms |
| 500   | 8.44 ms (8.39 to 8.47)    | 5.39 ms (5.18 to 5.72)    | −36%   | 80.0 ms            | 67.3 ms |
| 1000  | 16.84 ms (16.76 to 17.42) | 7.33 ms (7.26 to 7.47)    | −56%   | 160 ms             | 135 ms  |
| 2000  | 37.27 ms (36.99 to 38.16) | 20.74 ms (20.57 to 21.52) | −44%   | 323 ms             | 274 ms  |

The first mount at 100 nodes is the first in the process, so it includes one-time setup. In a later run with 1000 nodes first, the 100-node mount took 15 to 18 ms in every build.

Live, S2 100 with the screen asleep, n=5 each: instructions 1595 to 982 M/s (−38%), cycles 644 to 428 M/s (−34%), energy 58.9 to 32.2 mW (−45%), CPU 39.7 to 37.4%.

Limiter after the change: the main thread's AttributeGraph update and view comparisons, which grow with node count. Past 1000 nodes the 900-point column overflows the panel and stack layout must compress it, so the cost per frame steps from 7.3 ms at 1000 nodes to 11.4 ms at 1050.

## Unit 4: coalesce deliveries to the main thread

`MainDelivery` numbers each output a runtime sends. When the main queue reaches an output and a newer one from the same runtime is already queued, it skips the older one. Other events keep their order. An output holds every surface and display of its runtime, so the newest output per runtime is the newest per mount. `MainDeliveryTests` checks that of three queued outputs only the newest is applied, and that an event between them still runs in order.

Scenario `s6-launch-1000`: a 1000-node panel at 30 Hz summoned right after launch, traced. The post-launch flush stall reproduces with the display asleep, with 21 to 55 commits per run whose flush took over 100 ms, so this case runs with `--dark-ok`. Its absolute numbers with the screen on are still to be checked.

| s6-launch-1000, n=5 each                | Before (283472c)       | After (85bc924)      |
| --------------------------------------- | ---------------------- | -------------------- |
| Peak latency, trigger to flushed commit | 5521 ms (4865 to 7436) | 404 ms (378 to 417)  |
| Latency above 100 ms until              | 17.4 s (15.0 to 20.5)  | 13.3 s (9.4 to 14.7) |
| Last flush over 100 ms at               | 14.1 s (12.2 to 16.6)  | 13.3 s (9.4 to 14.7) |
| Commits applied in the run              | 1019 (625 to 1171)     | 394 (319 to 414)     |

After the change the latency is bounded by the stall itself: one stalled commit in progress plus the output's own, about two times 190 ms. Before, the main thread applied every stale output in order and fell 5 to 7 s behind. At steady state nothing changes: S2 100 measured 983 against 982 M instructions/s and 31.6 against 32.2 mW, n=5 each.

What this run adds about the stall: it happens with the display asleep, so display refresh does not cause it. In one run, slow flushes started at about 150 ms and grew to about 320 ms, about every 350 ms toward the end. Across runs they stop 9 to 17 s after launch. The cause is still open.

## Unit 5: node cap

`Node.maxNodes` stays at 1000.

The rule from the brief: raise the cap to a round number below the node count at which a 30 Hz panel needs about 16.7 ms per frame (half of a 33 ms frame) on the main thread, or on the plugin thread for parsing. Harness, build 85bc924:

| Nodes | Main thread frame p50, n=5 | Parse p50, n=5 |
| ----- | -------------------------- | -------------- |
| 1000  | 7.28 ms (7.24 to 7.31)     | 2.34 ms        |
| 1050  | 11.42 ms, n=3              | 2.44 ms        |
| 1100  | 11.61 ms, n=3              | 2.48 ms        |
| 1150  | 12.34 ms, n=3              | 2.63 ms        |
| 1200  | 12.62 ms (12.57 to 12.73)  | 2.74 ms        |
| 1400  | 14.63 ms (14.61 to 14.65)  | 3.22 ms        |
| 1600  | 16.36 ms (16.32 to 16.53)  | 3.61 ms        |
| 2000  | 20.62 ms (20.53 to 20.71)  | 4.53 ms        |

- Parsing costs about 2.3 µs per node, so the plugin thread would reach 16.7 ms near 6,000 nodes. JavaScript and the tree comparison add about 0.35 ms per 1000 nodes.
- The main thread steps up just past 1000 nodes, where the column overflows the panel, then grows about 10 µs per node. The harness reads 20 to 25% low against the screen-on numbers and leaves out about 3 ms of display-cycle work per frame. Scaled by that, 1050 nodes already need about 15 to 18 ms live (inferred).

So the main thread reaches half of a 30 Hz frame within a few percent above 1000 nodes, and no round number above 1000 meets the rule. A panel whose content does not overflow grows only about 4 µs per node between 500 and 1000 nodes. A bench with a scroll node could justify a higher cap later, but this harness does not show it.

## Unit 6: keep each node's structure when its effects or minWidth change

Unit 3 skipped the visual effects and the `minWidth` frame with `@ViewBuilder` branches. A branch change gives the subtree a new identity, so a node that gained or lost `opacity`, `x` or `minWidth` between renders rebuilt its children. Text fields lost their text and focus, hover and press state reset, scroll positions reset, and a change to the default value snapped instead of animating. `TreeViewIdentityTests` types into an input inside a row and toggles each of the nine properties off and on. It fails on 5552630 and passes now.

Every node now has the same structure:

- `VisualEffects` applies scale, rotation and offset as one `TransformEffect`, a `GeometryEffect`, followed by blur, opacity and blend. `LoopEffect` adds the static offset to its own, so a loop's scale and rotation still apply before the static offset.
- `MinWidth` is a `Layout` that passes sizes through when `minWidth` is nil and otherwise sizes and places like `.frame(minWidth:alignment:)`. It reports no explicit alignment guides. Gary's stacks, grids and frames align only to leading, center, trailing and top, and no Gary view sets those guides explicitly, so every position stays the same.
- A spacer node gets its parent's axis and wraps its `Spacer` in a one-item stack on that axis. A `Layout` hides the stack axis from a `Spacer` inside it, which made spacers grow in both directions.

`NodeEffectTests` checks the effects and the loop against SwiftUI's own modifiers pixel by pixel, checks `MinWidth` against `.frame(minWidth:)` for six alignments, and checks that a spacer grows along its row or column only. A scratch render of one tree with spacers in every container kind, `minWidth` with leading, center and trailing alignment, and every effect gave a byte-identical PNG and identical AppKit view frames against 5552630.

### Candidates

Harness, frame p50 at 1000 nodes, n=5 per variant, alternated, load average about 2. The first five rows keep 5552630's `minWidth` branch. The rows marked "probe" leave out loops, so they only measure cost and cannot ship.

| Candidate                                                                                 | Frame p50                 |
| ----------------------------------------------------------------------------------------- | ------------------------- |
| 5552630, branches                                                                         | 7.27 ms (7.23 to 11.74)   |
| One `ViewModifier` with the built-in effects                                              | 8.26 ms (8.24 to 8.41)    |
| Same, plain-value fields only (probe)                                                     | 8.18 ms (8.15 to 8.24)    |
| One `.visualEffect` closure plus `blendMode` (probe)                                      | 8.32 ms (8.29 to 8.34)    |
| One `GeometryEffect` for scale, rotation and offset, plus blur, opacity and blend (probe) | 7.86 ms (7.82 to 8.01)    |
| Same with the loop state and reduce-motion setting in that modifier                       | 8.31 ms (8.28 to 8.39)    |
| 5552630's effects with a `MinWidth` that forwards alignment queries                       | 7.30 ms (7.27 to 7.31)    |
| Built-in effects, `MinWidth` without alignment guides                                     | 7.76 ms (7.72 to 8.11)    |
| `GeometryEffect`, `MinWidth` that forwards alignment queries                              | 8.01 ms (7.95 to 8.21)    |
| `GeometryEffect`, `MinWidth` without alignment guides (kept)                              | 7.39 ms (7.38 to 7.43)    |
| `.frame(minWidth:)` on every node, alignment cut at containers only, n=3                  | 14.94 ms (14.89 to 14.95) |

- Wrapping the effects in a custom modifier saves nothing. Each effect costs about the same whatever its value. Per 1000 nodes, blur costs about 0.03 ms, opacity 0.07 ms, blend 0.14 ms, and `scaleEffect`, `rotationEffect` and `offset` together 0.5 ms (probes, n=3). One `GeometryEffect` in their place costs 0.25 ms.
- Alignment queries were the larger cost. When `MinWidth` forwards them, each parent stack walks the whole subtree, and at 2000 nodes, where the column overflows and is compressed, the frame takes 28.34 ms (28.23 to 28.39) against 20.14 ms (20.09 to 20.15) with the cut.
- A `@ViewBuilder` branch on every node costs about 0.5 ms per 1000 nodes even when both sides have the same type: 7.87 against 7.38 ms, n=3. So the spacer is handled inside the spacer case, not with a branch in every node's box.
- The flexible frame costs about 7 µs per node by itself, so `MinWidth` replaces it.

### Result

Harness, n=5 per build, alternated:

| Nodes | Frame p50, unit 2         | 5552630                   | Unit 6                    | First mount, 5552630 | Unit 6  |
| ----- | ------------------------- | ------------------------- | ------------------------- | -------------------- | ------- |
| 100   | 5.11 ms (4.52 to 5.22)    | 4.50 ms (4.28 to 4.74)    | 4.69 ms (4.54 to 4.80)    | 49.8 ms              | 35.6 ms |
| 500   | 8.39 ms (8.32 to 8.43)    | 5.46 ms (5.18 to 5.83)    | 5.45 ms (5.11 to 5.54)    | 67.0 ms              | 79.5 ms |
| 1000  | 16.84 ms (16.73 to 17.15) | 7.23 ms (7.19 to 7.32)    | 7.39 ms (7.38 to 7.43)    | 134 ms               | 159 ms  |
| 2000  | 37.10 ms (36.91 to 38.23) | 20.66 ms (20.50 to 20.74) | 20.14 ms (20.09 to 20.15) | 271 ms               | 324 ms  |

At 100 and 500 nodes the ranges overlap, so there is no measurable difference. At 1000 nodes a frame takes 0.16 ms (2%) longer, and at 2000 nodes 0.5 ms (3%) less, because the alignment cut saves more than the extra effects cost once the column is compressed. The first mount at 1000 and 2000 nodes is back at unit 2's 159 and 320 ms, since every node builds its effects again. The 100-node mount is the first in the process, as in unit 3.

## Unit 7: the post-launch flush stall comes from a Shortcut, not from Gary

The user's `sndrgrdn.weather` bar widget runs `shortcuts run "Current Weather"` when it loads. macOS then shows a Shortcuts Live Activity in the menu bar. For about 10 s, `MenuBarAgent` and `WidgetRenderer_Activities` redraw that activity without pause and keep the Core Animation render-server thread of WindowServer fully busy. Every commit from every process waits on that thread, and Gary's commits are no exception. No Gary code changed in this unit, because nothing in Gary's launch path is slow.

The benchmarks inherit the user's `shell.json`, so every bench launch ran the Shortcut. `s6-launch-1000` measured the Shortcut, and so did the stall notes in `BASELINE.md` and unit 4.

### Evidence

- `sample` of Gary during the stall, in `s6-launch-1000`: of 1242 main-thread samples in `CATransaction.flush()`, nearly all wait in `mach_msg` on WindowServer. 515 wait for a fence for AppKit's window-server transaction (`_NSCGSTransactionGetEntanglingHandle_`). 359 wait to send the commit. 336 wait in `CABackingStoreSynchronize` for the server to release a layer's backing store.
- `xctrace record --template "Time Profiler" --all-processes` during a launch, which works without root: for about 10 s after launch, the `com.apple.coreanimation.render-server` thread of WindowServer used a full core, in `CA::Render::Server::server_thread` handling command streams. In the same seconds, the main thread of `MenuBarAgent` used a full core inside its Core Animation commit handlers, and `WidgetRenderer_Activities` used about 1.75 cores. `ShortcutLiveActivityWidgetExtension` was running. Both Gary processes were almost idle.
- `flushprobe.swift` is a separate process that recolors a layer and flushes at 20 Hz. While Gary launched, its flushes took up to 486 ms. With no launch, none took over 3 ms. So the stall hits every process that commits.

Bisect: CPU time that `MenuBarAgent` and WindowServer used in the 16 s after `open` of a release build of fd63ef0. Each launch started after `MenuBarAgent` had been idle for 3 s. Display asleep.

| Gary launch                                                               | `MenuBarAgent` CPU | WindowServer CPU   | Runs |
| ------------------------------------------------------------------------- | ------------------ | ------------------ | ---- |
| User's config                                                             | 9.1 s (8.5 to 9.2) | 7.0 s (6.5 to 7.3) | 3    |
| User's config without `sndrgrdn.weather`                                  | 0.0 s and 1.6 s    | 0.10 s and 0.14 s  | 2    |
| Only `sndrgrdn.weather` in the bar                                        | 8.6 s              | 7.0 s              | 1    |
| Only `sndrgrdn.dinky`, `front-app`, `battery` or `clock` in the bar       | 0.0 s each         | 0.08 to 0.11 s     | 1    |
| No bar widgets and no plugins                                             | 0.0 s              | 0.09 s             | 1    |
| User's config, start stopped after `refreshDisplays`, before plugins load | 0.0 s              | 0.08 s             | 1    |

The Shortcut alone, with no Gary launch and the user's Gary left running, against a control that runs nothing. `flushprobe` ran for 20 s and the Shortcut started 2 s in. n=5 per side, alternated, 15 s apart:

| Side                              | Probe flushes over 100 ms | Slowest probe flush | `MenuBarAgent` CPU  | WindowServer CPU      |
| --------------------------------- | ------------------------- | ------------------- | ------------------- | --------------------- |
| Control                           | 0 (0 to 0)                | 2 ms (1 to 3)       | 0.0 s               | 0.22 s (0.21 to 0.29) |
| `shortcuts run "Current Weather"` | 10 (9 to 13)              | 430 ms (390 to 511) | 9.3 s (9.2 to 12.7) | 8.0 s (6.8 to 10.6)   |

The Shortcut itself returns after 1.1 s. The Live Activity keeps the three processes busy for about 9 s more.

The first bisect runs were confounded. Each bench run ends by relaunching the user's Gary, whose weather widget starts its own storm, and that storm overlapped the next launch. `render.py` now waits until WindowServer has used under 10% CPU for 3 s in a row before it launches Gary, and records the wait as `quiet_wait_s`. After a relaunch of the user's Gary the wait is 14 to 15 s.

### Before and after

`s6-launch-1000-bare` is `s6-launch-1000` with the user's bar widgets and plugins removed, so the bench Gary loads only `bench.busy`. Both cases ran on the same release build of fd63ef0, traced, display asleep, load average 2.2 to 3.2, n=5 each, alternated with `ab.sh`. Flush counts cover every commit in the first 20 s after the supervisor started.

| s6, n=5 each                            | User's config, with the weather widget | Without the user's widgets |
| --------------------------------------- | -------------------------------------- | -------------------------- |
| Flushes over 100 ms in the first 20 s   | 26 (24 to 48)                          | 0 (0 to 0)                 |
| Slowest flush in the first 20 s         | 350 ms (321 to 664)                    | 14 ms (14 to 15)           |
| Flushes in the first 20 s               | 382 (246 to 423)                       | 510 (510 to 511)           |
| `since` p95 in the measured 15 s        | 194 ms (15.5 to 318)                   | 15.5 ms (15.4 to 15.5)     |
| Commits per second in the measured 15 s | 19.9 (12.9 to 30.0)                    | 30.0 (30.0 to 30.0)        |
| WindowServer CPU in the measured 15 s   | 41.9% (1.9 to 71.7)                    | 1.6% (1.5 to 1.7)          |

Without the widgets, every flush of the first 20 s takes under 15 ms. The panel's first commit lands 0.4 s after launch, and the panel then commits 30 times per second until the run ends at about 17 s. Every run settled, had no error and no `failed` line, and rendered 30.1 times per second, so both sides did the same plugin work. The weather side's slowest run, 664 ms, launched only 3 s after the user's Gary had come back. Its storm likely overlapped that one (inferred). In the bare runs the limiter is the main thread's SwiftUI update, `layout` p50 10.9 ms, and flush p95 is 0.37 ms.

### What this means

- Any plugin that runs a Shortcut stalls every app's drawing for about 10 s, each time it runs. The weather widget does so at load, every 15 minutes, and 10 s after the screen unlocks. The blocking commit seen in a test process at 780446a fits this if the user's Gary ran the Shortcut during that test run (inferred, not reproduced).
- Gary has nothing to warm up. With the user's other widgets, its bar window, the tooltip panel, the theme and a 1000-node panel, no flush took over 15 ms.
- The fix belongs in `sndrgrdn.weather` in `sndrgrdn/gary-plugins`, which is outside this repository. It should fetch the weather without Shortcuts. The bare column bounds the gain.
- `s6-launch-1000` keeps the user's config, so it still shows the stall while the user's bar has the weather widget.

Rerun from the repository root. These commands quit and relaunch the user's Gary.

    scripts/bundle.sh
    APPS=build/Gary.app RUNS=5 CASES="s6-launch-1000 s6-launch-1000-bare" scripts/bench/ab.sh --trace --dark-ok
    swiftc -O -o tmp/bin/flushprobe scripts/bench/flushprobe.swift
    tmp/bin/flushprobe 20 0.05 > tmp/bench/probe.txt & sleep 2; shortcuts run "Current Weather"; wait

## Screen-on A/B: main 780446a against 2917722

Run on 2026-11-22 with the screen on and unlocked, release builds, 5 runs per side alternating, no failed lines, every run settled. Load average 1.9 to 4.8 on both sides. Raw lines are in `tmp/bench/display-ab.jsonl`.

    APPS="tmp/apps/base/Gary.app tmp/apps/head/Gary.app" RUNS=5 CASES="s2-busy-500 s2-busy-1000 s3-first-1000 s4-static s4-loops s4-shader s6-launch-1000-bare" scripts/bench/ab.sh

| Case                | Metric                      | 780446a                   | 2917722                   |
| ------------------- | --------------------------- | ------------------------- | ------------------------- |
| s2-busy-500         | Gary CPU                    | 50.7% (50.6 to 54.0)      | 40.3% (40.0 to 40.8)      |
| s2-busy-500         | instructions                | 9882 M/s                  | 4186 M/s                  |
| s2-busy-500         | energy                      | 3548 mW                   | 782 mW (781 to 1332)      |
| s2-busy-1000        | Gary CPU                    | 101.9% (101.6 to 108.6)   | 49.8% (49.7 to 50.2)      |
| s2-busy-1000        | instructions                | 19563 M/s                 | 8173 M/s                  |
| s2-busy-1000        | energy                      | 7213 mW                   | 3355 mW                   |
| s3-first-1000       | cold summon to first commit | 236.5 ms (233.0 to 237.6) | 225.8 ms (223.7 to 234.8) |
| s6-launch-1000-bare | Gary CPU                    | 100.6%                    | 50.0%                     |
| s4-static           | Gary CPU, WindowServer CPU  | 0.1%, 10.9%               | 0.1%, 10.9%               |
| s4-shader           | Gary CPU, WindowServer CPU  | 10.6%, 45.9%              | 10.6%, 46.2%              |
| s4-loops            | Gary instructions           | 286 M/s                   | 248 M/s                   |
| s4-loops            | WindowServer CPU            | 48.7% (48.7 to 55.5)      | 58.8% (55.8 to 59.8)      |

- At 1000 nodes the old build kept one core at 100% and still drew 30 frames a second, so the main thread was saturated. The new build halves it.
- S3 moved by 4%, close to the run-to-run range.
- s4-loops is a regression in WindowServer: about 10 points more CPU with ranges that do not overlap. Gary's own work fell. The likely cause is unit 6, which draws a loop's offset through `TransformEffect`.
- Loops and shaders redraw at 120 Hz (123 to 167 wakeups a second) and cost WindowServer 46 to 59% CPU. Rank 5, capping them, is still open.

## Open issues

- `GestureViewTests` "a scroll node with a scroll action scrolls and sends the action" skips itself while the display sleeps, because AppKit then never moves the scroll view.
- The post-launch flush stall comes from the `sndrgrdn.weather` widget's Shortcut (unit 7). Its fix belongs in `sndrgrdn/gary-plugins`.
- S5 still parses the whole 200 KB state in JavaScript on every render.
- A node that gains or loses `shadow`, `clip`, `material`, `colorScheme`, a click action, or a `loop` still rebuilds its subtree. These branches predate unit 3.
- `JSON` is no longer `Decodable`. Nothing in the repository decoded it with `Codable`.

## One shared JavaScriptCore VM: main 4ba2e1a against 3f48125

3f48125 runs every plugin in one `JSVirtualMachine`, with a context per plugin, through `PluginEngine`. Measured on 22 November 2026, Apple M4 Pro, with Sander's own Gary and other sessions running. Load average was 1.7 to 4.1, so the sides alternate.

    REVS="4ba2e1a 3f48125" RUNS=5 SECONDS_PER_RUN=60 scripts/bench/engine.sh

`engine.sh` builds each commit from `git archive` with `EngineBench.swift` added to its tests, in release with `-enable-testing`, and runs one test process per run. On a commit without `PluginEngine` it drops the lines that name the engine. `engine.py` prints the table.

`EngineBench` loads Sander's plugins from `~/Developer/gary-plugins` with their real capabilities: both dinky kinds, front-app, weather, battery, clock, and the theme service and menu. It adds `bench.busy` as a shown panel at 1000 nodes and 30 Hz. Every 150 to 250 ms, each at random, it publishes `clock` and `battery` and calls dinky's `focus-changed`, which runs three real `dinky` commands. The wait of a bar widget runs from the publish until its queue has run the update: the topic handler, the render and the node parse. A marker queued behind the update records it. Memory is the process footprint above the footprint before the first plugin loaded, sampled each second. After the 60 s, a runaway widget spins in `onAction`.

| 5 runs each, median (range) | main 4ba2e1a, a VM per plugin | 3f48125, one VM          |
| --------------------------- | ----------------------------- | ------------------------ |
| Bar widget wait p50         | 0.40 ms (0.36 to 0.41)        | 0.62 (0.56 to 0.69)      |
| p95                         | 0.63 ms (0.57 to 0.67)        | 1.92 (1.88 to 2.40)      |
| max                         | 1.61 ms (1.53 to 4.08)        | 6.51 (5.25 to 6.86)      |
| Plugin memory               | 23.9 MB (23.6 to 24.8)        | 16.2 (15.3 to 17.9)      |
| False kills                 | 0                             | 0                        |
| Runaway stopped after       | 104 ms (103 to 104), 5 of 5   | 103 (103 to 104), 5 of 5 |
| Other plugins kept running  | 5 of 5                        | 5 of 5                   |

- Each run took 862 to 894 widget samples, from clock, weather and battery. Dinky's state did not change, so the hub dropped its publishes, and dinky's widget and front-app took no samples. The panel delivered 30.3 to 30.5 frames a second on both sides, and the only failure in any run was the deliberate runaway.
- One VM uses 7.7 MB less, without Effect. The ranges do not overlap.
- One VM adds about 1.3 ms at p95, and the ranges do not overlap. The p95 was 2.0 ms or less in 4 of the 5 runs and 2.40 ms in the fifth.
- The limiter is the engine lock. An unreported run that timed the lock showed bar widgets waiting 0.8 to 1.0 ms at p95 to take it. Most of that wait is behind the panel, which holds the lock 0.09 ms at p50, 1.0 ms at p95 and up to 5.5 ms for its render and `JSON.stringify`. Clock and weather also wait for each other, because one `clock` publish wakes both. The lock was held 3.4% of the time.
- Before the change, JavaScriptCore stopped healthy plugins in a shared VM. In the spike harness, with a callback that recorded each request and never stopped anything, JavaScriptCore asked to stop the panel 0.2 ms into its call, after 0.2 ms of thread CPU (1 request in 3 runs of 60 s). Its watchdog keeps one CPU deadline per VM, and that deadline did not come from the call that was running. The engine now stops a call only when its own record says the call is at least 100 ms old.

## Who holds the engine lock: profile of main be2bf7f

Profiled on 22 November 2026, Apple M4 Pro, load average 3.1 to 5.9, in runs that are not reported as timings. `engine-profile.patch` times every `PluginEngine.run`: how long it waited for the lock, which plugin held the lock when it asked, and how long it held it. With `GARY_TRACE=1` it also splits each busy-panel frame into the stages Gary already traces.

    GARY_TRACE=1 PATCH=scripts/bench/engine-profile.patch REVS=be2bf7f RUNS=1 scripts/bench/engine.sh

The patch applies only to commits that have `PluginEngine`. The holder is read just before the wait, so a wait near zero may name a plugin that had already finished.

Three 60 s runs at be2bf7f, one with tracing and GC logging (`JSC_logGC=true`), one without either, one through the command above:

| Holder of the lock      | Held p95, ms | Held max, ms | Held in 60 s, ms | Bar widget time spent waiting behind it, ms |
| ----------------------- | ------------ | ------------ | ---------------- | ------------------------------------------- |
| dinky's service         | 8.1 to 11.0  | 19 to 21     | 1299 to 2830     | 224 to 841                                  |
| `bench.busy` panel      | 0.73 to 1.01 | 5.5 to 6.1   | 869 to 1678      | 78 to 255                                   |
| clock and weather       | 0.12 to 0.20 | 1.1 to 4.2   | 32 to 62 each    | 82 to 161, each waiting for the other       |
| JavaScriptCore full GCs | 2.5          | 3.7          | 100 in 71 GCs    | not attributed                              |

- The limiter is dinky's service, not the panel. Each `focus-changed` call runs three `host.exec` commands. Since 7c466cf, `ExecRuns.start` creates two scratch files and spawns the process on the plugin queue inside the JavaScript call, so the spawn holds the engine lock: 8 to 11 ms at p95, up to 21 ms. 3f48125, measured above, still spawned on a global queue, so its 1.92 ms p95 is not today's main.
- The widget waits at be2bf7f in these runs were p95 2.9 and 10.2 ms, max 10.5 and 16 ms.
- A busy-panel frame holds the lock 0.32 to 0.89 ms at p50: `render` 0.13 to 0.41, `JSON.stringify` 0.11 to 0.28, `JSON.parse` of the state 0.06 to 0.13, the timer handler 0.01 to 0.02. Swift parses the JSON and the nodes after the lock is released, 7.1 ms at p50 in the traced run.
- Garbage collection is a small share: the busiest log had 71 full collections in about 70 s, 1.3 ms at p50 and 3.7 ms at most.

## Engine layouts with ten Effect plugins

Sander's plugins, the busy 1000-node panel and 10 generated Effect plugins (6 bar widgets ticking each second, 4 services). 3 alternating runs of 15 s per layout, 0 false kills. Median (range). Measured on branch `engine-pool` (cd74e62, 18457d3), which adds a pool layout to `PluginEngines`.

| Layout               | Widget wait p50     | p95              | max              | Plugin memory | Per added Effect plugin | 10 Effect plugins load |
| -------------------- | ------------------- | ---------------- | ---------------- | ------------- | ----------------------- | ---------------------- |
| Engine per plugin    | 0.07 ms (0.06–0.07) | 0.47 (0.43–0.47) | 1.55 (1.11–1.78) | 135.0 MB      | 7.3 MB                  | 263 ms                 |
| Two engines, by kind | 0.07 (0.05–0.07)    | 0.45 (0.43–0.58) | 2.72 (2.52–2.74) | 40.2 MB       | under 0.1 MB            | 70 ms                  |
| Pool of 4            | 0.06 (0.05–0.07)    | 0.51 (0.38–0.53) | 1.12 (1.08–1.92) | 55.1 MB       | 0.6 MB                  | 86 ms                  |

Two engines ship. p50 and p95 differ by less than the spread. The two-engine max is about 1 ms higher because the six widgets load together and tick in step on the one bar engine; real widgets load apart and queue less.
