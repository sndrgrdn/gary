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

## Pending checks with the screen on

Run these from the repository root with the screen unlocked. They quit and relaunch the user's Gary. `tmp/apps/base` is the rebased build 8a11dbb, and `build/Gary.app` is the head of this branch.

    scripts/bundle.sh
    APPS="tmp/apps/base/Gary.app build/Gary.app" RUNS=5 CASES="s2-busy-500 s2-busy-1000 s3-first-1000 s4-static s4-loops s4-shader s6-launch-1000" scripts/bench/ab.sh
    APPS="tmp/apps/base/Gary.app build/Gary.app" RUNS=3 CASES="s2-busy-500 s2-busy-1000 s3-first-1000 s6-launch-1000" scripts/bench/ab.sh --trace

If `tmp/apps/base` is gone, rebuild it:

    git worktree add --detach tmp/at-base 8a11dbb && (cd tmp/at-base && scripts/bundle.sh) && mkdir -p tmp/apps/base && cp -R tmp/at-base/build/Gary.app tmp/apps/base/

- S2 500 and 1000: main-thread time and CPU with the display cycle running. Units 2 and 3 should show here. This also checks the harness's 20 to 25% gap at 1000 nodes and with it the node cap decision.
- S3: first mount at 1000 nodes. The harness measured the mount alone at 160 ms before unit 3 and 135 ms after.
- S4: loops and shader should not move, since no unit changed them. The static control checks that unit 3 left non-animated nodes alone.
- `s6-launch-1000` with the screen on, against the 7.7 s backlog in `BASELINE.md`.
- Rank 5, capping or moving `loop` and shader animations, was not attempted. To measure it, profile each case with the screen on:

      /usr/bin/lockf -k /tmp/gary-live.lock python3 scripts/bench/render.py profile s4-loops 10 tmp/bench/s4-loops.txt
      /usr/bin/lockf -k /tmp/gary-live.lock python3 scripts/bench/render.py profile s4-shader 10 tmp/bench/s4-shader.txt
      python3 scripts/bench/profile.py tmp/bench/s4-loops.txt

## Open issues

- `GestureViewTests` "a scroll node with a scroll action scrolls and sends the action" fails while the display sleeps, on `main` 780446a too. Every other test passes.
- The post-launch flush stall has no known cause. Unit 4 bounds its latency but not the stall.
- S5 still parses the whole 200 KB state in JavaScript on every render.
- When a node without hover or pressed styles and without an animation gains or loses a visual effect, such as `opacity`, between renders, SwiftUI rebuilds its subtree, so text fields inside lose focus. The same holds for a node that gains or loses `minWidth`. Before unit 3 these changes kept the subtree.
- `JSON` is no longer `Decodable`. Nothing in the repository decoded it with `Codable`.
