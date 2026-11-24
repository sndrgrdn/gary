# Plugin runtime survey for a macOS desktop shell

Scope: choose a core language and a plugin approach for a full rewrite of a macOS-only desktop shell (bar, menus, panels, overlays) extended by plugins. This survey starts from the developer's stated requirements only. It does not look at the current codebase.

## Recommendation

1. **Core: Swift**, with AppKit and Core Animation for windows and drawing, and C or Objective-C shims where a private or C-only API needs it.
2. **Plugins: Luau.** Each plugin gets its own Luau VM, runs off the main thread, and is held to a time budget (Luau interrupts) and a heap cap (a custom allocator). Plugins return state and view descriptions. The Swift core does all drawing and owns every macOS API call.
3. **Heavy, blocking, or native work goes to separate processes** ("providers"): XPC services or plain child processes, run at background or utility QoS. They publish data to Luau plugins. They don't draw.
4. **Do not use native dylib plugins.** On macOS, Swift and Objective-C code cannot be unloaded, so every reload leaks. A dylib also shares the core's address space and scheduler, so it gives no resource isolation.

This is a two-tier design. Plugin code that runs every frame or on user input stays small, interruptible, and reloads in place. Anything that can't be bounded inside a VM moves into a process, where the OS can deprioritise it or kill it.

## Requirements and the criteria derived from them

| #   | Criterion                          | Derived from                                            | What "good" means                                                                                                           |
| --- | ---------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| C1  | macOS API reach of the core        | "hook into lots of internal and macOS-specific APIs"    | First-class access to AppKit, Core Animation, Metal, CoreGraphics, private frameworks, and C APIs, without lagging bindings |
| C2  | Frame-time safety                  | "hit the 120 FPS target no matter what"                 | Plugin code never runs on the main thread inside a frame. Runaway plugin code can be stopped within a bounded time.         |
| C3  | Reload latency and state retention | "hot-reloadable … faster reload is preferred"           | Reload in well under a second, without restarting the app, ideally keeping plugin state                                     |
| C4  | Per-plugin resource isolation      | "not for crashing but just for resource usage"          | Per-plugin CPU budgets, memory caps, and attribution, so one heavy plugin can't starve the others or the UI                 |
| C5  | Plugin execution speed             | "It should be fast"                                     | Low overhead for each call and for each value that crosses the boundary                                                     |
| C6  | Inspectability by an agent         | "an agent should be able to inspect literally anything" | Tracing, profiling, and per-plugin metrics that a command-line tool can record and export as text                           |
| C7  | Authoring language                 | "not too keen on the JavaScript", "any language"        | Not JavaScript. A full rewrite is acceptable, so the language can be chosen freely.                                         |
| C8  | Maturity and maintenance risk      | Implied by "full rewrite"                               | Actively maintained, used in production                                                                                     |
| C9  | Distribution constraints           | Implied by macOS-only                                   | Works under Hardened Runtime and notarization without broad security exceptions                                             |

## Findings

### Core language

**Swift (recommended).**

- Ghostty uses a Zig core but writes its macOS GUI in Swift with AppKit and SwiftUI ([ghostty.org/docs/about](https://ghostty.org/docs/about)). Its author says "modern macOS development effectively requires Swift… all the new fancy functionality and frameworks Apple is shipping is Swift-only" ([mitchellh.com](https://mitchellh.com/writing/ghostty-and-useful-zig-patterns)). That is a practitioner's opinion, not an Apple statement.
- Since macOS 14, AppKit provides view-bound display links that follow the display a view is on and suspend when the view is off-screen ([philz.blog](https://philz.blog/in-process-animations-and-transitions-with-cadisplaylink-done-right/)). Apple's WWDC21 session describes how display links work on 120 Hz ProMotion displays and recommends using `targetTimestamp` ([WWDC21 10147](https://developer.apple.com/videos/play/wwdc2021/10147/)).
- XPC has a Swift-native API (`XPCSession`, `XPCListener`) ([Apple XPC docs](https://developer.apple.com/documentation/xpc/xpcsession.md)).
- Swift's documented performance costs: class references are always reference counted, and "These reference count operations are expensive and unavoidable when using Swift classes" ([OptimizationTips.rst L492-L499](https://github.com/swiftlang/swift/blob/2941968e9542c9b9bedf1d64368f21849fa9ed04/docs/OptimizationTips.rst#L492-L499)). Dynamic dispatch and generics also cost something unless the compiler can devirtualise or specialise them (same document). So the render path needs discipline: value types, `final` classes, and whole-module optimisation.

**Rust with objc2 (runner-up).**

- objc2 provides mostly auto-generated bindings to AppKit, Foundation, Metal, and other frameworks. They are generated from the Xcode 16.4 SDKs, and the documented support range is macOS 10.12 to 15.5, so new APIs arrive only after the bindings are regenerated ([docs.rs/objc2](https://docs.rs/objc2/latest/objc2/)).
- Rust is the native embedding language for Wasmtime and Mun. That matters only if the plugin tier is Wasm or Mun.

**Zig, C++, and Objective-C.**

- Zig reaches Objective-C through a runtime bridge (Ghostty's `objc.Object` in `src/apprt/embedded.zig`). Even so, Ghostty's macOS GUI is in Swift ([ghostty.org/docs/about](https://ghostty.org/docs/about)).
- Objective-C still has full API reach, but by Ghostty's account Apple's newest frameworks are Swift-first (see above).
- Not evaluated further.

### Plugin approaches

| Approach                               | C2 frame safety                                                   | C3 reload                                                                | C4 isolation                                              | C5 speed                                 | C6 inspect                                   | C9 distribution                                                | Verdict                            |
| -------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------- | ---------------------------------------- | -------------------------------------------- | -------------------------------------------------------------- | ---------------------------------- |
| Native Swift/ObjC dylibs (`dlopen`)    | None (same threads)                                               | Leaks on every reload: ObjC or Swift classes make a dylib non-unloadable | None                                                      | Native                                   | Instruments                                  | Needs library validation relaxed for third-party code          | Reject                             |
| Function interposing (InjectionIII)    | None                                                              | Fast, but development-only                                               | None                                                      | Native                                   | Instruments                                  | Requires disabling library validation                          | Dev tool only                      |
| Rust hot-patching (Subsecond)          | None                                                              | ~130 ms claimed                                                          | None                                                      | Native                                   | Instruments                                  | Dev tooling, shipped via CLI                                   | Dev tool only                      |
| **Luau VM per plugin**                 | Interrupt at safepoints; VM can run on a worker thread            | Recompile source in-process; keep state via host                         | Per-VM allocator cap, memory categories, interrupt budget | Interpreter plus optional native codegen | Counters, coverage, memory dump, debug hooks | Codegen only needs JIT entitlement if enabled                  | **Recommend**                      |
| Lua 5.4 / LuaJIT                       | Debug hooks; LuaJIT JIT fails under Hardened Runtime (open issue) | Fast                                                                     | Allocator cap                                             | LuaJIT fast                              | Basic                                        | LuaJIT JIT problematic                                         | Inferior to Luau                   |
| Wasm (Wasmtime, components)            | Epoch/fuel interruption, async yield                              | Requires compiling guest (language toolchain)                            | `ResourceLimiter`, fuel, epochs                           | Near-native (JIT)                        | GuestProfiler, perfmap with samply           | Currently needs `allow-unsigned-executable-memory` in practice | Strong alternative                 |
| Wasm (WasmKit, Swift)                  | Not verified                                                      | Same as above                                                            | Not verified                                              | Interpreter ("reasonably fast")          | Not verified                                 | No JIT needed                                                  | Watch                              |
| Extism (on Wasmtime)                   | `timeout_ms` via epochs                                           | Same as Wasm                                                             | `max_pages`, timeout                                      | Wasmtime                                 | Wasmtime                                     | Same as Wasmtime; no Swift host SDK listed                     | Not a fit for Swift host           |
| Mun                                    | No interruption documented                                        | First-class hot reload of functions and structs                          | None documented                                           | LLVM AOT                                 | Not documented                               | Not verified                                                   | Too immature                       |
| Gravity                                | Not verified                                                      | Not verified                                                             | Not verified                                              | Interpreter                              | Not verified                                 | Not verified                                                   | Not evaluated deeply               |
| Python subinterpreters                 | GIL per interpreter                                               | Fast (scripts)                                                           | Shares process memory, FDs                                | Slow                                     | Good                                         | Not verified                                                   | Reject (weight, isolation caveats) |
| .NET collectible `AssemblyLoadContext` | No forced unload                                                  | Cooperative unload                                                       | None                                                      | JIT                                      | Good                                         | Not verified                                                   | Reject                             |
| Out-of-process (XPC, child processes)  | Full: OS scheduler, QoS, kill                                     | Restart process (fast for scripts)                                       | Strongest: OS-level                                       | IPC per call                             | Per-process in Instruments                   | Native fit                                                     | **Recommend for providers**        |
| JS engines (JSC, QuickJS, V8)          | n/a                                                               | n/a                                                                      | n/a                                                       | n/a                                      | n/a                                          | n/a                                                            | Excluded by C7                     |

Supporting evidence, by row.

**Native dylibs.**

- At WWDC 2017, Apple said that Objective-C classes, Swift classes, and thread-local variables in a dylib make it "not unloadable", and that `dlclose` "doesn't actually close the dylib" ([WWDC17 413 transcript](https://nonstrict.eu/wwdcindex/wwdc2017/413/)).
- The Objective-C runtime source re-`dlopen`s images that contain ObjC content, which prevents them from unloading (quoted in [this Stack Overflow answer](https://stackoverflow.com/questions/8793099/unload-dynamic-library-needs-two-dlclose-calls), citing objc4 `objc-os.m`; that is secondary, and I did not re-read objc4 myself).
- Apple's older `dlclose(3)` man page says dynamic libraries can be unloaded from 10.5, except in three listed cases ([Apple man page](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dlclose.3.html)). See Conflicts.

**InjectionIII.**

- It works by interposing symbols with `-Xlinker -interposable`. It cannot change memory layout (stored properties, vtables). On macOS it needs the app sandbox and library validation turned off during development ([InjectionIII README](https://github.com/johnno1962/InjectionIII/blob/main/README.md)).

**Subsecond.**

- It hot-patches Rust through explicit `subsecond::call` points and does not migrate struct layout changes ([Dioxus v0.7.0 release](https://github.com/DioxusLabs/dioxus/releases/tag/v0.7.0)).
- The 130 ms compile-and-patch time is the author's claim on an M4 ([HN](https://news.ycombinator.com/item?id=44369642)).

**Luau.**

- `lua_Callbacks.interrupt` "gets called at safepoints (loop back edges, call/ret, gc)" and may be set from another thread ([lua.h L617-L623](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L617-L623)).
- `lua_newstate` takes a custom allocator ([lua.h L132](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L132)), and `lua_setmemcat`/`lua_totalbytes` attribute bytes to categories ([lua.h L358-L359](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L358-L359)).
- The sandboxing guide says no memory limits apply by default but the host can configure them easily, and that interrupts cannot stop "a single C function that takes a lot of time" ([luau.org/sandbox](https://luau.org/sandbox/)).
- Native code generation is fully supported on A64 ([Luau recap, July 2024](https://luau.org/news/2024-07-23-luau-recap-july-2024/)).
- The same `lua.h` exposes `lua_getcounters`, `lua_getcoverage`, `lua_memorydump` (JSON), and debug hooks.

**LuaJIT.**

- Open issue: with `allow-jit`, the app "gets killed moments after it starts" under Hardened Runtime ([LuaJIT#1334](https://github.com/LuaJIT/LuaJIT/issues/1334)).

**Wasmtime.**

- Epochs cost about 10% and fuel costs more ([interrupting docs](https://docs.wasmtime.dev/examples-interrupting-wasm.html)).
- Neither epochs nor fuel interrupts a guest that is blocked in a host call ([Config::epoch_interruption](https://docs.wasmtime.dev/api/wasmtime/struct.Config.html)).
- `ResourceLimiter` caps memory and table growth but not host-side allocations ([ResourceLimiter](https://docs.wasmtime.dev/api/wasmtime/trait.ResourceLimiter.html)).
- With the pooling allocator, instantiation takes microseconds ([fast instantiation](https://docs.wasmtime.dev/examples-fast-instantiation.html); [Wasmtime 1.0 performance](https://bytecodealliance.org/articles/wasmtime-10-performance)).
- Profiling on macOS works with samply through perfmap, or with the cross-platform `GuestProfiler`, which writes Firefox-profiler JSON ([profiling docs](https://docs.wasmtime.dev/examples-profiling.html), [GuestProfiler](https://docs.wasmtime.dev/api/wasmtime/struct.GuestProfiler.html)).
- Zed builds its extensions on the Wasm component model and Wasmtime ([Zed blog](https://zed.dev/blog/zed-decoded-extensions)). Zed's shipped entitlements include both `allow-jit` and `allow-unsigned-executable-memory` ([zed.entitlements L7-L9](https://github.com/zed-industries/zed/blob/c016f436e60bfa5105de53837935e9de94eb0867/crates/zed/resources/zed.entitlements#L7-L9)).
- Wasmtime does not yet use `MAP_JIT` correctly on macOS. A downstream project reports it needs `allow-unsigned-executable-memory` ([wasmtime#11989](https://github.com/bytecodealliance/wasmtime/issues/11989)).

**WasmKit.**

- WasmKit is a Wasm runtime written in Swift and embeddable from Swift. It describes itself as "reasonably fast", and Swift 6.2+ toolchains include its CLI ([WasmKit README](https://github.com/swiftwasm/WasmKit)). I did not verify whether it offers interruption or resource limits.

**Extism.**

- The manifest offers `timeout_ms` and memory `max_pages` ([docs.rs/extism Manifest](https://docs.rs/extism/latest/extism/struct.Manifest.html)). The host SDK list has no Swift entry ([Extism host quickstart](https://extism.org/docs/quickstart/host-quickstart/)).

**Mun.**

- Mun's own site says it is "nowhere near production-ready" ([mun-lang.org](https://mun-lang.org/)).
- It hot reloads functions and structs, including struct field migrations ([Mun book](https://docs.mun-lang.org/ch04-04-hot-reloading)).

**Gravity.**

- A Swift-like, dynamically typed VM in C99 ([GitHub](https://www.github.com/marcobambini/gravity)). Its sandboxing and interruption features were not verified.

**Python subinterpreters.**

- Python 3.12+ supports a per-interpreter GIL. Interpreters still share process memory and file descriptors ([PEP 684](https://peps.python.org/pep-0684/); [C-API docs](https://docs.python.org/3/c-api/subinterpreters.html)).

**.NET.**

- Unloading an `AssemblyLoadContext` is cooperative. There is no forced unload, and it is a non-goal ([Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/standard/assembly/unloadability); [runtime design doc](https://github.com/dotnet/runtime/blob/main/docs/design/features/unloadability.md)).

**Out-of-process.**

- Apple's own guidance says plug-ins are a reason to use XPC services: "the stability of any application with a plug-in API is inherently at the mercy of the authors of plug-ins". launchd restarts crashed services and kills idle ones ([Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)).
- XPC services cannot present UI "except in a very limited way using IOSurface" ([Designing Daemons and Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/DesigningDaemons.html)). Chromium's cross-process `CALayerHost`/`CAContext` route is private API ([remote_layer_api.h](https://github.com/chromium/chromium/blob/main/ui/base/cocoa/remote_layer_api.h)).
- QoS classes tell the scheduler what to favour, and on Apple silicon they influence which cores a thread runs on ([Energy Efficiency Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html); [Apple silicon tuning](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon.md)).
- `setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)` lets a process put itself in background state, with lowest scheduling priority and throttled disk and network I/O ([setpriority(2)](https://keith.github.io/xcode-man-pages/getpriority.2.html)).

### Prior art in this exact domain

**SketchyBar.**

- A C daemon. Plugins are shell scripts or Lua (SbarLua), run out-of-process on events, and "forced to terminate after 60 seconds" ([SketchyBar events docs](https://felixkratz.github.io/SketchyBar/config/events)). The process boundary gives isolation, and each event pays a process-spawn cost.

**Hammerspoon.**

- An Objective-C bridge to an in-process Lua engine. Its README states "Hammerspoon v1 is currently unmaintained" ([GitHub](https://github.com/Hammerspoon/hammerspoon/)).

**Übersicht and simple-bar.**

- JavaScript widgets in a WebView. Excluded by C7.

**Moonframe.**

- Rust plus Luau plus Wasm "providers". It reloads Luau files with state kept, caps memory and instructions, and gives Wasm providers 64 MiB and a fresh instruction budget per call ([moonframe README](https://github.com/moonframehq/moonframe)).
- This is the same two-tier shape as the recommendation, which independently supports the design. These are product claims that I have not benchmarked.

### Inspectability for an agent (C6)

- `xctrace` records, exports to XML, and queries Instruments traces from the command line, including `os_signpost` intervals and Time Profiler ([xctrace(1)](https://keith.github.io/xcode-man-pages/xctrace.1.html)). Signposts are "a low-cost tracing primitive" ([WWDC19 414](https://developer.apple.com/videos/play/wwdc2019/414/)). A Swift core can wrap every plugin call, reload, and frame in signposts. An agent can then run `xctrace record` and `xctrace export` without a GUI.
- Luau adds per-VM counters, coverage, heap-category bytes, and JSON memory dumps (lua.h, above). The host can expose these through a local socket or CLI.
- Wasmtime adds `GuestProfiler` JSON and samply perfmaps (above).

## Inference (not directly proven by sources)

- **120 FPS is an architecture property, not a language property.** If the main thread only reads the last committed snapshot of each plugin's view tree and never waits on a plugin, a slow plugin shows stale content instead of dropping frames. Luau interrupts and Wasmtime epochs both bound runaway guest code. Neither bounds a slow host call (Luau sandbox guide; Wasmtime `Config` docs). So host bindings exposed to plugins must be non-blocking or asynchronous.
- **Luau beats Wasm on C3 for this developer.** Luau reloads by compiling source to bytecode in-process. A Wasm plugin first needs its guest toolchain (for example `cargo build`) to produce a new module. The Wasm compile step is outside the runtime, so reload speed depends on the language. I have no measured numbers for either.
- **Per-VM isolation is partial.** CPU budgets are cooperative at safepoints and memory caps apply only to VM allocations. Everything still shares one address space and one process's QoS. Only the provider processes get true OS-level isolation. That is why the recommendation uses both tiers.
- **Plugin worker threads should run below the main thread.** Running them at utility QoS, or giving each plugin a serial dispatch queue, lets the scheduler favour the main thread. This follows from Apple's QoS guidance. I have not measured it for this workload.

## Conflicting evidence

- **Can dylibs unload?** Apple's man page says dylibs can be unloaded since 10.5, with three exceptions. Apple's WWDC17 talk says ObjC classes, Swift classes, or TLS make a dylib "not unloadable", and that this "effectively… hasn't really worked" on other platforms. The talk is newer and more specific. I treat Swift plugin unloading as impossible in practice.
- **MAP_JIT regions.** Apple's porting guide says a hardened app can create only one `MAP_JIT` region. A Wasmtime maintainer observed two working locally ([wasmtime#11989](https://github.com/bytecodealliance/wasmtime/issues/11989); Apple guide via [mirror](https://apple-docs.everest.mt/docs/apple-silicon/porting-just-in-time-compilers-to-apple-silicon/), original at developer.apple.com, which I did not fetch directly).
- **Epoch cost.** The Wasmtime docs give the epoch overhead as "around a 10% slowdown" on one page, and say epochs are "up to 2-3x" faster than fuel on another. Both can hold, but the absolute costs are workload-dependent.

## Strongest case against this recommendation

**Swift core plus Wasmtime components (the Zed model), or a Rust core plus Wasmtime.**

- It meets "any language" (C7) literally. Plugins could be written in Rust, Zig, C, Swift (via SwiftWasm), or Go.
- Its isolation primitives are stronger and better documented than Luau's: deterministic fuel, async yield, and `ResourceLimiter`.
- Its sandbox comes from the Wasm memory model, not from a C++ VM that "isn't formally proven" (Luau's own words on [luau.org/sandbox](https://luau.org/sandbox/)).
- Compiled Wasm is likely faster than Luau for compute-heavy plugins.
- With a Rust core, the Wasm host is native.

**Why I still prefer Luau.**

- Reload speed was stated as a preference. Wasm reload goes through an external compiler.
- Wasmtime currently needs `allow-unsigned-executable-memory` on macOS (Zed's entitlements; wasmtime#11989).
- A Swift host would have to use Wasmtime's C API rather than its Rust API.

**When to switch.** If the developer values writing plugins in a compiled language over sub-second reload, choose Wasm components instead. The two-tier design still applies: Wasm becomes the in-process tier in place of Luau.

**A second objection: plugins as Swift modules compiled into the app.** This gives maximum speed and full API reach, and InjectionIII gives fast iteration during development. It fails C3 for users at runtime and fails C4 entirely.

## Could not verify

- Luau compile-and-swap time for a realistic plugin, and Swift-to-Luau call overhead per frame. No primary benchmark found.
- Whether WasmKit supports interruption or memory limits, and its speed relative to Wasmtime.
- Whether Luau native codegen works under Hardened Runtime with only `allow-jit`. Its interpreter does not need JIT.
- Gravity's maintenance status and sandbox features.
- Moonframe's and Tern's budget figures. Both are product documentation, not independent measurements.
- The objc4 source line that re-opens ObjC images. I relied on a quoted excerpt, not the source.
- Per-thread CPU attribution APIs (Mach `thread_info`) for in-process per-plugin CPU accounting. Not researched.

## Search log

| #   | Query or fetch                                                                                       | Candidates or facts found                                   |
| --- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1   | "macOS status bar replacement plugins architecture open source (SketchyBar, Hammerspoon, Übersicht)" | SketchyBar, SbarLua, Hammerspoon, simple-bar/Übersicht, obi |
| 2   | "wasmtime epoch interruption fuel ResourceLimiter memory limit documentation"                        | Wasmtime limits                                             |
| 3   | "embeddable scripting language hot reload sandbox CPU memory limits Luau interrupt"                  | Luau, rune-luau, Tern, Phosphor, Moonframe, OpenReliant     |
| 4   | "dlclose macOS does not unload Objective-C Swift image dyld"                                         | WWDC17 413, dlclose(3), SwiftGodot#384                      |
| 5   | "Apple developer CADisplayLink macOS NSView displayLink ProMotion 120Hz"                             | WWDC21 10147, NSView displayLink                            |
| 6   | "Zed extensions WebAssembly wasmtime component model extension API source"                           | Zed extensions                                              |
| 7   | "WasmKit Swift WebAssembly runtime embed host functions swiftwasm"                                   | WasmKit, SwiftWasm                                          |
| 8   | "Moonframe malleable desktop software Rust Luau"                                                     | Moonframe                                                   |
| 9   | "Rust hot reload subsecond dioxus hot-patching dylib macOS"                                          | Subsecond, ipbp                                             |
| 10  | "Apple developer documentation XPC services create XPC service macOS"                                | XPC, XPCSession                                             |
| 11  | "Apple Energy Efficiency Guide prioritize work quality of service classes macOS"                     | QoS                                                         |
| 12  | "IOSurface share rendering between processes macOS CALayer contents remote process"                  | IOSurface, CALayerHost (private)                            |
| 13  | "Mun programming language hot reloading embeddable Rust"                                             | Mun                                                         |
| 14  | "Gravity scripting language Swift-like embeddable Creolabs"                                          | Gravity                                                     |
| 15  | ".NET AssemblyLoadContext collectible unload plugins documentation"                                  | .NET ALC                                                    |
| 16  | "InjectionIII hot reloading Swift macOS app how it works dlopen interpose"                           | InjectionIII, InjectionLite                                 |
| 17  | "xctrace command line record export Instruments trace os_signpost"                                   | xctrace, os_signpost                                        |
| 18  | "wasmtime profiling guest profiler perfmap jitdump macOS samply"                                     | Wasmtime profiling                                          |
| 19  | "objc2 crate Rust bindings Apple frameworks AppKit generated header-translator"                      | objc2                                                       |
| 20  | "Apple hardened runtime entitlement com.apple.security.cs.allow-jit MAP_JIT"                         | JIT entitlements, LuaJIT#1334                               |
| 21  | "Luau native code generation arm64 luau_codegen performance"                                         | Luau codegen                                                |
| 22  | "Ghostty macOS app Swift AppKit libghostty Zig core architecture README"                             | Ghostty (Zig core plus Swift GUI)                           |
| 23  | "PEP 684 per-interpreter GIL subinterpreters embedding C API"                                        | Python subinterpreters                                      |
| 24  | "Extism plugin system WebAssembly host SDK Swift runtime timeout memory limit"                       | Extism                                                      |
| 25  | "wasmtime pooling allocator instantiation fast microseconds copy-on-write"                           | Wasmtime instantiation                                      |
| 26  | "setpriority PRIO_DARWIN_BG PRIO_DARWIN_PROCESS man page"                                            | Darwin background state                                     |
| F1  | Fetch wasmtime#11989                                                                                 | MAP_JIT status on macOS                                     |
| F2  | Fetch Swift `docs/OptimizationTips.rst` @2941968                                                     | ARC and dispatch costs                                      |
| F3  | Fetch Zed `zed.entitlements` @c016f43                                                                | Shipped JIT entitlements                                    |
| F4  | Fetch Luau `VM/include/lua.h` @97b2f4b                                                               | Interrupt, allocator, memcat, debug APIs                    |

Candidates I considered from background knowledge but did not search, and excluded on C7 or scope: JavaScriptCore, QuickJS, V8 (JavaScript); Wren, Janet, Rhai, Roto, Koto, AngelScript (no macOS-specific advantage found; not searched, so this is a gap); Dart VM hot reload (embedding it is outside the Flutter path; not searched).

## Pinned sources inspected

| Repository         | Revision                                 | Files                                   |
| ------------------ | ---------------------------------------- | --------------------------------------- |
| luau-lang/luau     | 97b2f4bf9cd935bed666f3e643a3b749b4d22f38 | `VM/include/lua.h`                      |
| zed-industries/zed | c016f436e60bfa5105de53837935e9de94eb0867 | `crates/zed/resources/zed.entitlements` |
| swiftlang/swift    | 2941968e9542c9b9bedf1d64368f21849fa9ed04 | `docs/OptimizationTips.rst`             |

None of these are cloned locally. They were fetched as raw files at the listed commits.
