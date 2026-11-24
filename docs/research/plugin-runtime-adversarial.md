# Plugin runtime: adversarial review

Research note, November 2026. It attacks the recommendation in [`plugin-runtime-architecture.md`](plugin-runtime-architecture.md) and [`plugin-runtime-survey.md`](plugin-runtime-survey.md): a Swift core, plugins in Luau with one VM per plugin off the main thread, a main thread that only draws each plugin's last finished state, and helper processes ("providers") for heavy or blocking work.

Evidence labels: **Source** is official documentation, a specification, source code, or an issue tracker, cited inline. **Inferred** is my conclusion from sources. **Caller** is a requirement quoted by the developer.

## Verdict

The recommendation survives in shape. I found no fatal flaw, and no alternative beats it on the developer's stated requirements. It does not survive as written. The notes aim their defenses at the wrong threat, overclaim what the design guarantees, and skip the costs of embedding Luau in Swift.

- **The frame guarantee is false as stated.** "A slow plugin shows stale content instead of dropping frames" holds only for plugin _execution_. What a plugin _returns_ still costs main-thread time: tree diffing, layout, text, the Core Animation commit, and render-server work. A plugin that returns a large or effect-heavy tree drops frames with no plugin code on the main thread.
- **The likelier frame-dropper is the core, not plugins.** The survey has the Swift core "own every macOS API call". Several of those calls are synchronous IPC with timeouts measured in seconds.
- **Embedding Luau in Swift has a trap the notes miss.** By default Luau raises errors as C++ exceptions, including out-of-memory errors from any allocating API. Swift terminates the process when a C++ exception reaches Swift code.
- **"Hot reload with state kept" is opt-in plain data, and providers do not hot-reload at all.** The prior art the notes measure (rune-luau) keeps only plain data across a reload. Closures, metatables, coroutines, and userdata are lost. A provider written in a compiled language reloads at its compiler's speed.
- **Per-plugin memory caps miss most of the memory.** The Luau cap covers the script heap. In this design most per-plugin memory lives on the host side: materialized view trees, images, layers, and provider buffers.

Each of these can be fixed, and the fixes belong in the architecture before any code is written. The ranked list follows.

## Ranked attacks

| #   | Attack                                                                    | Severity | Mitigable?                                                                        |
| --- | ------------------------------------------------------------------------- | -------- | --------------------------------------------------------------------------------- |
| A1  | Plugin output, not plugin code, can still drop frames                     | Serious  | Yes: output budgets, off-main diffing, host-owned interactions                    |
| A2  | Core's own synchronous macOS calls block the main thread                  | Serious  | Yes: same off-main rule for the core, with a short allowlist of main-thread calls |
| A3  | Luau errors unwind as C++ exceptions through Swift frames                 | Serious  | Yes: C++ trampoline layer; never let `lua_error` cross Swift                      |
| A4  | Hot reload keeps plain data only; providers reload slowly                 | Serious  | Partly: explicit state schema, host-tracked resources, script providers           |
| A5  | Memory caps miss host-side allocations                                    | Serious  | Yes: per-plugin host accounting and quotas                                        |
| A6  | Synchronous AppKit APIs (menus) and interaction latency                   | Serious  | Yes: precomputed menus, host-side interaction states                              |
| A7  | Provider tier is undesigned: XPC cannot host plugin code, cost unmeasured | Serious  | Yes: child processes with own IPC; measure before committing                      |
| A8  | Interrupt gaps in builtins; no emergency GC under a cap                   | Minor    | Yes: cap sizing, per-plugin threads                                               |
| A9  | Swift Concurrency's cooperative pool cannot host long Luau slices         | Minor    | Yes: dedicated threads or serial queues                                           |
| A10 | Luau C API churn and Roblox-driven roadmap                                | Minor    | Yes: vendor and pin                                                               |
| A11 | Agent fluency and tooling for Luau                                        | Minor    | Partly: ship type definitions and `luau-analyze` in the loop                      |
| A12 | Diagnosability gaps specific to an async, multi-process design            | Serious  | Yes: barrier, trace IDs, per-plugin frame attribution                             |
| A13 | Factual errors and weak citations in the notes                            | Minor    | Correct the notes                                                                 |

No attack reached **fatal**: none rules out the design or forces a different runtime.

## A1. Plugin output can still drop frames (serious)

**Source.**

- Apple splits hitches into commit hitches (main thread misses the commit deadline) and render hitches (render server misses its deadline), and says "a render hitch is usually due to the app, such as when the scheduled UI update is too complex to render in time" ([Apple, understanding hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)). The main thread and the render server "each have only a single vsync interval" (same page).
- SwiftUI's `View` is `@MainActor` ([Apple, View](https://developer.apple.com/documentation/swiftui/view)), so `body` and the diff of a SwiftUI tree run on the main thread. The architecture note already cites this (its section 7).
- Gary's current host turns plugin output into native views (`Sources/gary/NodeViews.swift`, `NodeBox.swift`, `NodePaint.swift`, `NodeShader.swift`), and `tree`, `click`, and `hover` commands act on those trees (`Sources/GaryCore/IPC.swift`, the `CommandUsage` list from line 244).

**Inferred.**

- The main thread does work proportional to what each plugin returns: diff the new tree against the old, update views or layers, lay out, shape text, and commit. A plugin that returns 20,000 nodes, a per-frame animated custom shader, or many blurred and masked layers drops frames while its own code runs on a worker. The notes' claim "a slow plugin shows stale content instead of dropping frames" (survey, Inference) holds for execution time only.
- Interrupts and CPU budgets on the worker do not touch this cost. The design has no mechanism that bounds it.

**Mitigation.**

- Diff on the worker and send the main thread a patch, not a tree. Cap patch size per plugin per frame; coalesce or defer the rest.
- Give each plugin an output budget: node count, layer count, expensive effects (blur, shadows without paths, masks, custom shaders), and text runs. Measure main-thread apply time per plugin and degrade or freeze a plugin that exceeds it.
- Keep animations in the host: declared in the tree, run by Core Animation or SwiftUI's built-in animatable effects, which run "off the main thread and without calling into any of your view code" ([WWDC23, Explore SwiftUI animation](https://developer.apple.com/videos/play/wwdc2023/10156/)).

## A2. The core's own synchronous calls block the main thread (serious)

**Source.**

- Accessibility calls are synchronous messages to another app. `AXUIElementPerformAction` can fail with `kAXErrorCannotComplete` when "the application has not yet responded", and the timeout is set in seconds through `AXUIElementSetMessagingTimeout` (macOS SDK, `HIServices.framework/Headers/AXUIElement.h`, lines 317-331 and 386-402, Xcode SDK on this machine).
- The survey assigns "every macOS API call" to the Swift core (survey, Recommendation, item 2).
- Gary already reaches private and entitled functionality through a separate process: MediaRemote runs under `/usr/bin/perl`, because that platform binary "is entitled to use the MediaRemote framework" ([mediaremote-adapter README L18-L21](https://github.com/ungive/mediaremote-adapter/blob/65714990277cb4d0415ebaf7fff6be3229362b28/README.md#L18-L21); `scripts/bundle.sh`, lines 30-42).

**Inferred.**

- In a shell, the usual cause of a frozen bar is a blocking system call to a hung app or daemon: Accessibility, window lists, private window-server calls. A plugin's request such as "focus this window" turns into exactly such a call in the core. The notes guard only against plugin code on the main thread.
- The survey's "core owns every API call" and "heavy work goes to providers" pull in different directions. It does not say which side owns blocking system IPC.

**Mitigation.** Apply the off-main rule to the core too. Keep a short allowlist of calls that must run on the main thread (AppKit views and windows, per [Apple, Thread Safety Summary](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html)). Run everything else on core workers with per-call timeouts and signposts.

## A3. Luau errors unwind through Swift frames (serious)

**Source.**

- Luau raises errors with C++ exceptions unless built with `LUA_USE_LONGJMP=1`, which defaults to 0 ([`luaconf.h` L64-L67](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/luaconf.h#L64-L67); [`ldo.cpp` L33-L66](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/ldo.cpp#L33-L66)).
- An allocation failure throws `LUA_ERRMEM` at the failing allocation. There is no emergency collection first ([`lmem.cpp` L315-L321](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lmem.cpp#L315-L321); no match for "emergency" under `VM/src`).
- "Swift does not support catching C++ exceptions. Instead, the running program terminates with a fatal error when a C++ exception that's not caught by C++ code reaches Swift code" ([swift.org, Mixing Swift and C++, C++ Exceptions](https://www.swift.org/documentation/cxx-interop/)).
- 32 of `lua.h`'s calls are function-like macros, such as `lua_pop`, `lua_tostring`, `lua_newtable`, and `lua_pushcfunction` ([`lua.h` L501-L545](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L501-L545)). Swift does not import function-like macros, so a C or C++ shim is required anyway.

**Inferred.**

- Any Swift host function registered as a `lua_CFunction` that calls `luaL_check*`, `luaL_error`, or any allocating API (`lua_pushstring`, `lua_createtable`) can throw through its own Swift frame. With a per-plugin memory cap, allocation failures are expected, so this is a normal path, not a corner case. Building with `longjmp` instead skips Swift's releases and `defer` blocks, which leaks and can leave locks held.
- The notes name "host-call overhead from Swift through a C shim" as an open question (architecture note, open question 2) but not this.

**Mitigation.** Put a thin C++ layer between Luau and Swift. Every Swift host function returns a status and never calls a raising Luau API; the C++ trampoline converts the status into `lua_error` after Swift returns. Swift calls into the VM only through `lua_pcall` wrappers in C++ that catch `lua_exception`. Test it by forcing `LUA_ERRMEM` inside every host function.

## A4. Hot reload keeps plain data only (serious)

**Source.**

- rune-luau, which the notes use for their 0.54 ms and 1.04 ms reload numbers, reloads by starting a new VM. The old VM's `saveHotState` returns a value, and the new VM's `loadHotState` receives it ([`script.rs` L491-L522](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/script.rs#L491-L522)).
- That value is `Data`: nil, booleans, numbers, strings, arrays, and string-keyed maps, "without functions, threads or userdata". A deeper or cyclic table "stops there as `nil`" ([`data.rs` L10-L28](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/data.rs#L10-L28)).
- Luau has no `__gc` for tables. Only host-registered userdata destructors run, "right before freeing the userdata memory block" ([Luau, sandbox, `__gc`](https://luau.org/sandbox)).

**Inferred.**

- State that survives a reload is whatever the plugin author serializes. Closures, metatables (object identity and class behavior), coroutines in flight, userdata handles, and non-string keys are lost, and cycles turn into `nil` without an error. A schema change between versions is the plugin's problem: `loadHotState` gets the old shape.
- The host holds references the script cannot see: timers, subscriptions to providers, in-flight async completions, open panels. A reload must cancel or re-route each one, or the old VM's callbacks fire into the new VM. A script cannot clean these up from a finalizer, because Luau has none.
- A provider written in Swift or Rust reloads at its compiler's speed (seconds), loses its in-memory state, and keeps running the old protocol until restarted. The "fastest reload" argument for Luau applies only to the Luau tier.

**Mitigation.** Make reload a host protocol: the host owns every resource per plugin generation and tears down the previous generation's resources. State migration takes an explicit version number. Prefer providers written in Luau too (a Luau VM in a helper process) so they share the reload path, and keep compiled providers for the few that need native APIs.

## A5. Memory caps miss host-side allocations (serious)

**Source.** Luau: a cap "is easy to configure from the host for Luau allocations, but of course with a rich API surface exposed by the host it's hard to eliminate" exhaustion ([Luau, sandbox](https://luau.org/sandbox)). Native code blocks also bypass `lua_Alloc`: `CodeAllocator` maps them with `mmap` directly ([`CodeAllocator.cpp` L86-L97](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CodeGen/src/CodeAllocator.cpp#L86-L97)).

**Inferred.** In this design, a plugin's Luau heap holds its model. Its real footprint is on the host: Swift copies of its view tree, `NSImage` and `CGImage` decodes, layers and backing stores, text layout caches, and buffers for provider messages. One image-heavy plugin can exhaust memory while its Luau heap stays under the cap. The caller wants isolation "for resource usage" (**Caller**), and only a host ledger provides that.

**Mitigation.** Account every host allocation made on a plugin's behalf (images, nodes, layers, provider buffers) to that plugin, with a quota per kind. Report it next to `lua_totalbytes`.

## A6. Synchronous AppKit APIs and interaction latency (serious)

**Source.** `NSMenuDelegate.menuNeedsUpdate(_:)` is `@MainActor` and is "invoked when a menu is about to be displayed at the start of a tracking session". The slower alternatives `numberOfItems(in:)` and `menu(_:update:at:shouldCancel:)` are also `@MainActor` and synchronous ([Apple, menuNeedsUpdate](<https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:)>); [numberOfItems(in:)](<https://developer.apple.com/documentation/appkit/nsmenudelegate/numberofitems(in:)>)).

**Inferred.**

- Where AppKit asks for content synchronously (menus, key equivalents, drag validation, tooltips), the main thread cannot wait for a plugin's worker. It must use a precomputed answer, or the design breaks its own rule.
- Every plugin-driven reaction to input is a round trip: main thread, plugin worker, new tree, main thread. That adds at least one frame, more under load. Hover states and drags that depend on plugin logic will lag at 120 Hz.

**Mitigation.** Plugins publish menus and interaction states (hover, pressed, drag targets) ahead of time as data. The host handles them without a round trip, and only the resulting action goes to the plugin.

## A7. The provider tier is undesigned (serious)

**Source.**

- An XPC service "is a bundle in the Contents/XPCServices directory of the main application bundle". launchd launches it on demand and "terminates them (by sending SIGKILL) when they are idle" ([Apple, Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)).
- The architecture note found no primary source for helper footprint or XPC latency and measured only `/bin/sleep` at 1.1 MB (its section 8).

**Inferred.**

- A third-party plugin's provider cannot be an XPC service: adding a bundle to `Contents/XPCServices` breaks the app's signature. Providers must be plain child processes with their own IPC, lifecycle, crash handling, and log capture. The survey lists both options without noting this.
- The provider language is unspecified. If it is Swift or Rust, plugin authors need a second toolchain, a build step, code signing for the binary, and a second reload story (A4). That is a large part of "the plugin system", and the notes treat it as an aside.
- Cost per provider (footprint, launch time, round-trip latency) is unmeasured. I found no primary source for these either.

**Mitigation.** Define providers as child processes that run a Luau VM plus a fixed set of host-provided native modules, speaking one IPC protocol. Native providers become a core-team escape hatch rather than a plugin-author feature. Measure footprint, launch time, and round-trip latency before committing.

## A8. Interrupt gaps and memory-cap behavior (minor)

**Source.**

- Pattern matching calls the interrupt at each `match` step ([`lstrlib.cpp` L431-L445](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lstrlib.cpp#L431-L445)), so the notes' worry about long string operations is partly unfounded.
- `string.rep` fills its buffer with `memcpy` and no safepoint ([`lstrlib.cpp` L86-L115](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lstrlib.cpp#L86-L115)). `table.concat` loops without one ([`ltablib.cpp` L319-L341](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/ltablib.cpp#L319-L341)). `table.sort` reaches a safepoint only through a Lua comparator call ([`ltablib.cpp` L395-L407](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/ltablib.cpp#L395-L407)).
- The interrupt can stop execution: after the callback, the VM exits if the thread's status changed ([`lvmexecute.cpp` L90-L102](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lvmexecute.cpp#L90-L102)). Time slicing by yielding is therefore possible.
- The atomic GC step "can result in occasional pauses on the order of tens of milliseconds" and may "scale with the application heap" ([Luau, performance](https://luau.org/performance)).

**Inferred.**

- Builtins without safepoints are bounded by the memory cap: they can only touch as much data as the heap holds. With a 64 MB cap that is a few to a few hundred milliseconds on one worker, not the main thread.
- GC pauses stall only the plugin's own VM, and bar plugins have small heaps. That makes GC a fairness issue, not a frame-rate issue.
- The GC goal defaults to 200% (architecture note, 1.3). Without an emergency collection, a plugin whose live data is near half its cap gets `LUA_ERRMEM` while garbage remains (A3 decides whether that is a clean error or a crash).

**Mitigation.** Set the cap at least twice the expected live heap, or call `lua_gc` with a full collection on a soft threshold from the host. Give busy plugins their own thread instead of a shared worker.

## A9. Swift Concurrency cannot host long Luau slices (minor)

**Source.** Swift's cooperative pool creates "only as many threads as there are CPU cores", and relies on "a runtime contract that threads are always able to make forward progress" ([WWDC21, Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)).

**Inferred.** Wrapping each plugin VM in an actor on the default executor puts CPU-bound script slices of up to the budget (100 to 250 ms in the notes' examples) on the cooperative pool. A few busy plugins then starve every other async task in the core, including XPC replies and timers. Use dedicated threads or serial dispatch queues at utility QoS for VMs.

## A10. Luau C API churn (minor)

**Source.**

- Luau ships weekly `0.x` releases (0.744 on 23 October to 0.748 on 20 November 2026, [releases](https://github.com/luau-lang/luau/releases)). `VM/include/lua.h` changed in 23 commits in the year to 24 November 2026, mostly "Sync to upstream/release" ([history](https://github.com/luau-lang/luau/commits/master/VM/include/lua.h)).
- Two were breaking C API changes: [`c6b8301`](https://github.com/luau-lang/luau/commit/c6b830185af962c82003f86784e2fe036357c830) "Change lua_newuserdatadtor to accept a lua_Destructor callback [breaking C API change]" (September 2026) and [`813167a`](https://github.com/luau-lang/luau/commit/813167ac12c38e2e018e53a6567b25c13efa6d77) "Pass a lua_State parameter to useratom" (February 2026).
- VM behavior sits behind runtime fast flags; `VM/src/*.cpp` references `FFlag::` 113 times at `97b2f4b`. Example: the caged-heap path in [`lmem.cpp` L303-L313](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lmem.cpp#L303-L313).
- Luau's users outside Roblox are games: "Alan Wake 2, Farming Simulator 2025, Second Life, and Warframe" ([README L8](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/README.md#L8)).

**Inferred.** Roblox sets the roadmap, and embedders absorb occasional breaking changes and flag flips. The C API is small, so pinning a release and upgrading deliberately is enough.

## A11. Agent fluency and tooling (minor)

**Source.**

- The language server is third-party: [JohnnyMorganz/luau-lsp](https://github.com/JohnnyMorganz/luau-lsp), active (last push 24 November 2026).
- The Luau repo ships a REPL, `luau-analyze`, a coverage tool, and a sampling profiler, but no debug adapter ([`CLI/src`](https://github.com/luau-lang/luau/tree/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CLI/src)). The VM offers breakpoints, single-step, and debug callbacks to build one ([`lua.h` L573-L574, L632-L635](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L573-L635)).
- Hammerspoon, the closest macOS precedent for scripting a desktop in Lua, has moved off it. Hammerspoon 2 is "a modern rewrite that you script in JavaScript instead of Lua", on JavaScriptCore ([hammerspoon.org](https://www.hammerspoon.org/)), and v1 is "currently unmaintained" ([issue #3916](https://github.com/Hammerspoon/hammerspoon/issues/3916), opened 22 November 2026). The survey cites the unmaintained notice but not the move to JavaScript.

**Inferred.** Most public Luau is Roblox game code, so agents will reach for Roblox APIs (`game:GetService`, `Instance.new`) that do not exist here. This is not measured. Type definitions for Gary's API, `luau-analyze` run on every edit, and a short skill file go most of the way. TypeScript has the larger corpus and type checker, which is the strongest argument for staying with JavaScript (see Alternatives).

## A12. Diagnosability: what an agent cannot inspect (serious)

**Source.**

- Gary today exposes `tree`, `click`, `hover`, `key`, `scroll`, `call`, `reloadPlugins`, and `doctor` to the command line (`Sources/GaryCore/IPC.swift`, from line 244).
- Luau exposes counters, coverage, memory categories, and a JSON heap dump (`lua_getcounters`, `lua_getcoverage`, `lua_setmemcat`, `lua_memorydump` in [`lua.h` L351-L359, L602-L610](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L351-L610)).

**Inferred.** The survey's answer to "inspect literally anything" (**Caller**) is `xctrace` plus Luau's counters. An async, multi-VM, multi-process design needs more:

1. **A settle barrier.** After `gary click`, the tree is stale until the plugin's worker finishes and the main thread applies the patch. Without "wait until plugin X is idle and its patch is applied", every agent test is racy.
2. **Causal trace IDs** carried from input event to plugin entry, provider request, patch, and commit, across threads and processes.
3. **Per-plugin frame attribution:** main-thread apply time and commit size per plugin per frame (A1). Otherwise a hitch cannot be pinned on a plugin.
4. **Eval in a running plugin VM**, with a per-plugin REPL over the existing socket, and dumps of hot state, host-held resources (A4), and the host memory ledger (A5).
5. **Provider introspection:** state, queue depth, restart count, and captured stdout and stderr per provider.
6. **Step debugging** needs a debug adapter built on Luau's debug callbacks. None exists.

None of these is hard. All of them are missing from the notes.

## A13. Factual problems in the notes (minor)

| Claim                                                                             | Note                           | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------------------------------------------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LuaJIT under the hardened runtime is an "open issue"                              | Survey                         | Outdated. [LuaJIT#1334](https://github.com/LuaJIT/LuaJIT/issues/1334) closed 9 March 2025. Support landed behind a build option (`LUAJIT_ENABLE_OSX_HRT`, per the thread). LuaJIT is still a poor fit, but not for this reason.                                                                                                                                                                                                                                                                                 |
| Luau's JIT "compiles only functions or modules marked for it"                     | Architecture 1.6               | Overstated. Marking is opt-in through `CodeGen_OnlyNativeModules` ([`CodeGenOptions.h` L14-L20](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CodeGen/include/Luau/CodeGenOptions.h#L14-L20)).                                                                                                                                                                                                                                                                                |
| rune-luau skips native code on macOS; the hardened runtime is "a plausible cause" | Architecture 1.6 and Conflicts | Unsupported. rune's own comment gives memory as the cost: "a 4 MiB committed code block per VM, used or not" ([`Cargo.toml` L10-L14](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/Cargo.toml#L10-L14)). Luau's `SharedCodeGenContext` lets VMs share one allocator ([`CodeGen.h` L94-L123](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CodeGen/include/Luau/CodeGen.h#L94-L123)), so the 4 MiB per VM is rune's choice. |
| View-bound display links on macOS 14                                              | Survey                         | Cited to a blog ([philz.blog](https://philz.blog/in-process-animations-and-transitions-with-cadisplaylink-done-right/)). The architecture note cites Apple's own page for the same fact.                                                                                                                                                                                                                                                                                                                        |
| ObjC images are re-opened and never unload                                        | Survey                         | Cited to Stack Overflow. The architecture note's dyld source citation supersedes it.                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Moonframe "independently supports" the design                                     | Survey                         | A product README, not evidence of behavior.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Main thread runs at base priority 46                                              | Architecture 8                 | Incomplete. The frontmost app's user-interactive threads get 47 ([`thread_policy.c` L1099-L1105](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/thread_policy.c#L1099-L1105); [`task_policy.c` L836-L845](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/task_policy.c#L836-L845)). A shell is almost never frontmost, so its main thread ranks just below the focused app's.                 |
| objc2 bindings lag the SDK                                                        | Survey                         | Confirmed and worse than stated: as of November 2026, objc2 0.6.5 still generates from Xcode 16.4 ([docs.rs/objc2](https://docs.rs/objc2/latest/objc2/)) while Apple ships macOS 27 SDKs.                                                                                                                                                                                                                                                                                                                       |
| Wasmtime epochs cost about 10%                                                    | Survey                         | Confirmed ([wasmtime, interrupting](https://docs.wasmtime.dev/examples-interrupting-wasm.html)).                                                                                                                                                                                                                                                                                                                                                                                                                |
| Hammerspoon v1 unmaintained                                                       | Survey                         | Confirmed, but see A11 for what replaced it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

## Settled: Luau native code under the hardened runtime

The notes disagree. The survey says codegen "only needs JIT entitlement if enabled". The architecture note implies the hardened runtime may be why rune leaves native code off on macOS.

**Source.**

- On Apple platforms Luau maps every code block with `MAP_JIT`, writes it while read-write, then calls `mprotect` to make it read-execute and `sys_icache_invalidate` ([`CodeAllocator.cpp` L86-L113, L130-L138](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CodeGen/src/CodeAllocator.cpp#L86-L138)). It never calls `pthread_jit_write_protect_np` or `pthread_jit_write_with_callback_np`.
- Apple: with the hardened runtime, `mmap` with `MAP_JIT` needs `com.apple.security.cs.allow-jit`, "If you don't have this entitlement, calls using that flag return an error", and the app "can only create one memory region with the `MAP_JIT` flag set" ([Apple, porting JIT compilers to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)).
- Luau maps a new 4 MiB block each time a code allocator fills, up to 256 MiB ([`CodeGenContext.cpp` L26-L27](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CodeGen/src/CodeGenContext.cpp#L26-L27); [`CodeAllocator.cpp` L299-L312](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/CodeGen/src/CodeAllocator.cpp#L299-L312)).
- A wasmtime maintainer tested the same pattern (`MAP_JIT`, then `mprotect`) with only `allow-jit`, and it ran. He also created two `MAP_JIT` regions without failure, contrary to Apple's text ([wasmtime#11989, comments of 6 November and 5 December 2025](https://github.com/bytecodealliance/wasmtime/issues/11989)).

**Answer.** Under Gary's hardened runtime, Luau native code needs `allow-jit`; without it, code allocation fails and Luau runs in the interpreter. With `allow-jit`, Luau's pattern matches one that works in practice. It conflicts with Apple's documented one-region limit once more than one block exists: a second VM with its own context, or a shared context that grows past 4 MiB. **Not tested here.** The rules forbid building and running it. Neither note needs native code, since bar plugins are not compute-bound, so this does not affect the recommendation. If native code is ever enabled, use one `SharedCodeGenContext` with a block size large enough to stay at one region.

## The 120 FPS claim

What can still drop frames in this design, with the evidence for each:

| Cause                                            | Evidence                                                                                               | Design defends?            |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------ | -------------------------- |
| Plugin code on the main thread                   | Architecture note, sections 1 and 11                                                                   | Yes                        |
| Main-thread apply of large plugin output         | A1, [Apple hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app) | No                         |
| Render-server cost of complex layers and effects | "Render hitch is usually due to the app" (same page)                                                   | No                         |
| Core's synchronous system IPC                    | A2, `AXUIElement.h`                                                                                    | No                         |
| Synchronous AppKit callbacks needing plugin data | A6, `NSMenuDelegate`                                                                                   | No                         |
| Frontmost app's UI thread outranks the shell     | A13, xnu `thread_policy.c`                                                                             | No, and it cannot          |
| Low Power Mode caps ProMotion at 60 Hz           | rune `display_link.rs`, cited in the architecture note, section 5                                      | No, and it should not      |
| Provider processes contending for cores          | Architecture note, section 8 (QoS, clutch)                                                             | Partly, through QoS clamps |

**Inferred.** "120 FPS no matter what" (**Caller**) cannot be guaranteed by any app-side design: the render server, the frontmost app, and power policy are outside it. What the design can guarantee is that Gary's main thread meets each commit deadline. That requires A1, A2, and A6 on top of the notes.

## Alternatives, steel-manned

| Alternative                                                   | Best case                                                                                                                                                                                                                                                                                                                                                              | Fails on                                                                                                                                                          | Better than the recommendation?                                        |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **JavaScriptCore + TypeScript (today's Gary, Hammerspoon 2)** | Already built: Gary ships TSX plugins through Sucrase and JSC (`Sources/gary/Transpiler.swift`). Hammerspoon chose it for its rewrite (A11). System framework, no vendoring. Largest agent corpus and the best type checker.                                                                                                                                           | No public memory cap; the timeout API is private; about 3.5 MB per VM measured (architecture note, open question 3). Caller is "not too keen".                    | No on isolation; yes on agent ergonomics and migration cost            |
| **QuickJS-ng + TypeScript**                                   | Per-runtime `JS_SetMemoryLimit`, `JS_SetInterruptHandler`, and `JS_ComputeMemoryUsage` ([`quickjs.h` L527-L537, L629, L1213](https://github.com/quickjs-ng/quickjs/blob/d06a85c11f3cb8827be25414bcfe14eca40faf4e/quickjs.h#L527-L1213)); active (v0.18.0, 1 November 2026). Reference counting with a cycle collector gives short pauses. TypeScript tooling as above. | Transpile step in reload (milliseconds with Sucrase). Interpreter speed against Luau unmeasured. Still JavaScript.                                                | Tie on the requirements. Preference decides.                           |
| **Wasm components (Zed model)**                               | Strongest sandbox; any compiled language.                                                                                                                                                                                                                                                                                                                              | Reload goes through a guest toolchain; macOS JIT support in wasmtime is incomplete ([wasmtime#11989](https://github.com/bytecodealliance/wasmtime/issues/11989)). | No, on reload speed                                                    |
| **Rust + GPUI**                                               | Proven 120 Hz renderer.                                                                                                                                                                                                                                                                                                                                                | objc2 bindings lag the SDK (A13); GPUI also renders on the main thread (architecture note, 4.2). The core needs current and private macOS APIs (**Caller**).      | No                                                                     |
| **Hammerspoon-style in-process Lua on the main thread**       | Simplest; fastest calls.                                                                                                                                                                                                                                                                                                                                               | rune measured why: a busy script holds the UI thread for up to its budget (architecture note, section 5). Hammerspoon itself left Lua.                            | No                                                                     |
| **BEAM-style isolation**                                      | Preemptive scheduling and per-process heaps.                                                                                                                                                                                                                                                                                                                           | No embeddable BEAM with an AppKit story; a VM far larger than a shell needs (inferred, not searched in depth).                                                    | No                                                                     |
| **Process per plugin, Luau inside**                           | Kernel-enforced memory caps and QoS clamps per plugin, which the caller asked for (**Caller**: "resource usage").                                                                                                                                                                                                                                                      | IPC per update; about 1 MB or more per process (architecture note, section 8); unmeasured latency.                                                                | Possibly, for heavy plugins only. This is the provider tier, extended. |

The strongest challenger is **staying on JavaScript with TypeScript**, in JSC or QuickJS-ng. It wins on agent fluency, type tooling, migration cost, and precedent. It loses on JSC's missing memory cap and on the developer's preference. Luau remains a defensible choice, but the survey's case against JavaScript rests only on that preference, and it should say so.

## What I tried that did not break the design

- **GC pauses.** Real (tens of milliseconds at worst), but per VM and on a worker. Not a frame-rate threat (A8).
- **Pattern matching that never yields.** Luau checks interrupts inside `match` (A8).
- **Threading.** One VM per thread at a time is the documented model, and the interrupt is safe to set from another thread (architecture note, 1.4). Time slicing through yield from the interrupt is supported (A8).
- **Reload speed.** Luau's in-process compile is the fastest option found; nothing beat it.
- **launchd and process limits.** A handful of child processes is far below any limit I know of. I did not research per-user process limits in depth.

## Residual gaps

- Luau native code under the hardened runtime is settled from source and documentation, not by a test (Settled section).
- No primary numbers for helper footprint, launch time, or IPC latency (A7).
- No measurement of Swift-to-Luau call overhead or of main-thread apply cost per node (A1, A3).
- The claim that agents write worse Luau than TypeScript is inference, not measured (A11).
- Whether `xctrace` can profile a notarized Gary without `get-task-allow` was not checked. Apple's entitlement page did not load as Markdown.

## Sources inspected locally

| Repository                 | Revision                                                                               | Local path                                                 |
| -------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| luau-lang/luau             | `97b2f4bf9cd935bed666f3e643a3b749b4d22f38`                                             | `~/.cache/checkouts/github.com/luau-lang/luau`             |
| anomalyco/rune             | `baf7c39c3c4442a3bab7a9a2381720ca4bee9414`                                             | `~/.cache/checkouts/github.com/anomalyco/rune`             |
| Hammerspoon/hammerspoon    | `23e387e2805a9890066366e0ac96c71b27f0cfd5` (README read at current `master` over HTTP) | `~/.cache/checkouts/github.com/Hammerspoon/hammerspoon`    |
| ungive/mediaremote-adapter | `65714990277cb4d0415ebaf7fff6be3229362b28`                                             | `~/.cache/checkouts/github.com/ungive/mediaremote-adapter` |
| sndrgrdn/gary              | `2445588`                                                                              | `/Users/sander/Developer/gary`                             |

Fetched as single files: xnu `f6217f8` (`osfmk/kern/task_policy.c`, `osfmk/kern/thread_policy.c`); quickjs-ng `d06a85c` (`quickjs.h`); the macOS SDK header `AXUIElement.h` from the local Xcode.
