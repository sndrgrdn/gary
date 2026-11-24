# Plugin runtime architecture: 120 FPS with busy plugins

Research note, November 2026. It asks which core language, plugin runtime, and renderer let a rewritten Gary hold 120 FPS on a ProMotion display while several plugins are busy. It also covers per-plugin limits on CPU, memory, and scheduling, and how fast each runtime reloads.

Sections 1 to 9 hold findings, each backed by a source. Section 10 compares the runtimes. Section 11 holds inference: what the findings imply for 120 FPS. Section 12 lists open questions.

Evidence labels:

- **Source** means official documentation, a specification, or source code, cited inline.
- **Measured** means a local spike measurement. The scale harness is `tmp/lang-spike/scale/measure.sh`, and its output is `tmp/lang-spike/scale/results.tsv`. `ps` reports CPU time in 10 ms steps.
- **Inferred** marks a conclusion drawn from sources, not stated by them.

## Answer in short

This answer is inferred from the findings below.

- **Keep plugin code off the main thread, whatever the runtime.** At 120 Hz the main thread has 8.3 ms to commit each frame ([Apple, hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)). Every runtime here stops runaway code only after tens to hundreds of milliseconds: 100 ms in Gary's JavaScriptCore engine, 250 ms in rune-luau, and a 100 ms epoch tick in Zed. Any plugin call on the main thread can therefore drop 12 to 30 frames.
- **Plugin runtime: Luau, one VM per plugin, run on worker threads.** It has the fastest reload (0.54 ms and 1.04 ms measured), a per-VM allocator for an exact Luau heap cap, an interrupt for a CPU-time budget, and about 0.7 MB per instance (measured). Use wasmtime instead only if plugins must come from many languages or need memory-safe isolation. Its reload then includes the guest's own toolchain build plus a Cranelift compile, and no primary source gives the time.
- **Renderer: either works.** SwiftUI and Core Animation can keep up if the main thread only applies prepared view state. A Metal renderer paced by `CAMetalDisplayLink`, as in GPUI, gives more control over frame pacing. The sources do not show that SwiftUI cannot reach 120 FPS for a bar. They do show that `body` and the Core Animation commit run on the main thread.
- **Core language: the sources do not decide it.** Luau has a C API. Rust has `mlua`, wasmtime, GPUI, and rune. Swift has SwiftUI, Gary's existing code, and WasmKit. A process per plugin is the only way to get kernel-enforced memory caps and QoS clamps per plugin.

## 1. Luau

### 1.1 CPU limits: the interrupt callback

- **Safepoints.** `lua_Callbacks.interrupt` "gets called at safepoints (loop back edges, call/ret, gc) if set". It is "safe to set from an arbitrary thread", while other callbacks may change only when the VM runs no code ([`lua.h` L615-L623](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L615-L623)). The interpreter calls it before advancing `pc` and exits if the callback raised an error ([`lvmexecute.cpp` L90-L102](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lvmexecute.cpp#L90-L102)). The garbage collector calls it too, with the GC state as its second argument ([`lgc.cpp` L132-L134](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lgc.cpp#L132-L134)).
- **Gap: C functions.** Luau calls the interrupt "eventually", at any call or loop iteration. A single long C function call stays unbounded ([Luau, sandbox](https://luau.org/sandbox)).
- **Roblox's limits.** Roblox's watchdog limits a script in Studio to 10 seconds, and on shutdown interrupts every script after 1 second ([Luau, sandbox](https://luau.org/sandbox)).
- **rune-luau's budget.** rune-luau charges each VM entry 250 ms of the thread's CPU time, not wall time. It reads the clocks every 256 safepoints. A wall-clock backstop of 20 budgets (5 s) stops an entry on a starved CPU ([`watchdog.rs` L1-L14, L29, L126-L146](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/watchdog.rs#L1-L146)). Its comment explains the switch: a wall-clock deadline stopped a plugin's start-up while a build loaded the machine.

### 1.2 Memory: per-VM allocators and heap caps

- **Allocator per VM.** `lua_newstate(lua_Alloc allocator, void* ud)` takes an allocator per VM. The allocator has the `realloc`-like signature `(ud, ptr, osize, nsize)` ([`lua.h` L55, L132](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L55-L132)). Luau also has a newer `lua_setmemorycage` for a caged heap, set right after `lua_newstate` ([`lua.h` L59, L650-L653](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L650-L653)).
- **No built-in cap.** "By default, no memory limits are imposed", and a cap "is easy to configure from the host for Luau allocations". Memory that host APIs allocate is harder to bound ([Luau, sandbox](https://luau.org/sandbox)).
- **mlua's cap.** mlua's allocator returns `NULL` when an allocation would push used memory past the limit ([mlua v0.12.3 `memory.rs` L87-L127](https://github.com/mlua-rs/mlua/blob/cbd45a79ffdcf424314eaf43b51dcb6807ef5297/src/memory.rs#L87-L127)). rune-luau sets a 64 MB default per VM ([`vm.rs` L138](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/vm.rs#L138); [`options.rs` L63-L64](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/options.rs#L63-L64)). rune-luau pins mlua at `a0ad4535`, and I read v0.12.3, so the allocator may differ slightly.

### 1.3 Garbage collection: pacing and pauses

- **Incremental, with assists.** Collection is incremental and never stops the world to walk the whole heap. Work happens in "GC assists" as the script allocates, or on explicit `lua_gc` calls. Luau recommends that game engines "request garbage collection every frame" so that most GC work runs outside script execution. The pacer is a PID controller that targets a heap size as a percentage of live data ([Luau, performance](https://luau.org/performance)).
- **Defaults.** The goal defaults to 200% (the heap may grow to twice the live data), the step multiplier to 200%, and the step size to 1 KB ([`lgc.h` L12-L14](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/src/lgc.h#L12-L14); [`lua.h` L312-L339](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L312-L339)).
- **Pauses.** The once-per-cycle atomic step "can result in occasional pauses on the order of tens of milliseconds". Luau reduces it with a remark step, incremental marking of coroutines, and shrinkable weak tables ([Luau, performance](https://luau.org/performance)).
- **rune-luau's timing.** rune-luau runs one `gc_step` after each batch of script work, "so garbage from this batch is swept between frames rather than in the middle of a render" ([`script.rs` L338-L342](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/script.rs#L338-L342)).

### 1.4 Threading model

- **No locking in the VM.** Luau's headers declare no `lua_lock` and no thread-safe entry points. Only `interrupt` is documented as safe to set from another thread ([`lua.h` L615-L618](https://github.com/luau-lang/luau/blob/97b2f4bf9cd935bed666f3e643a3b749b4d22f38/VM/include/lua.h#L615-L618)). So one VM runs on one thread at a time, and separate VMs may run on separate threads (inferred).
- **mlua.** `Lua` is `!Send` by default. The `send` feature makes it `Send + Sync` behind a reentrant mutex ([mlua `lib.rs` L48-L57](https://github.com/mlua-rs/mlua/blob/cbd45a79ffdcf424314eaf43b51dcb6807ef5297/src/lib.rs#L48-L57)). A VM can therefore live on a worker thread, moved there or created there.
- **Roblox.** Parallel Luau runs scripts under different `Actor`s on separate threads. Scripts under one actor run in sequence. Parallel code calls `task.desynchronize()` and must call `task.synchronize()` before it writes most engine state. Roblox advises against long unyielding computations even in parallel ([Roblox, Parallel Luau](https://create.roblox.com/docs/scripting/multithreading)). The page does not say whether each actor has its own VM.

### 1.5 Reload speed

- **Compile throughput.** With all optimizations on, Luau "compiles 950K lines of Luau code in 1 second on a single core" of a Ryzen 5900X ([Luau, performance](https://luau.org/performance)). Gary's largest plugin has about 1,240 lines (`docs/research/plugin-api-design.md`, section 1), so compiling it should take about a millisecond (inferred).
- **rune-luau's reload.** A reload saves hot state, starts a new VM, runs `init.luau`, and restores the state. A compile error keeps the running VM ([`script.rs` L493-L534](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/script.rs#L493-L534)). When watching, it compiles on the file watcher's thread and prebuilds the VM base, so the next poll only swaps ([`watch.rs` L1-L3](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/watch.rs#L1-L3)). Its benchmark gates compile plus swap at 5,000 µs or less ([`bench.rs` L264](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/examples/luau-panel/src/bench.rs#L264)).
- **Measured.** In the anomalyco/rune bar spike, the power plugin reloaded in 0.54 ms and the clock plugin in 1.04 ms (`~/Developer/gary-spike-anomaly-rune/spike/results/README.md`, "Hot reload").

### 1.6 Native code

- **Luau.** Luau has an optional JIT for x64 and arm64 that compiles only functions or modules marked for it ([Luau, performance](https://luau.org/performance)).
- **rune-luau.** rune-luau enables native code only on Windows and Linux. Each VM then commits a 4 MiB code block, and 21 VMs in OpenCode held 88 MB this way ([`Cargo.toml` L10-L14](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/Cargo.toml#L10-L14); [README L100-L104](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/README.md#L100-L104)). On macOS, scripts run in the interpreter.
- **Hardened runtime.** The Hardened Runtime forbids writable and executable memory unless the app has the `allow-jit` entitlement ([Apple, allow-jit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)). Gary signs with `--options runtime` (`scripts/bundle.sh:43`).

### 1.7 How Roblox schedules scripts in a frame

- **No per-script slices documented.** The task scheduler runs a fixed order of stages each frame and resumes scripts waiting in `task.wait()` ([Roblox, task scheduler](https://create.roblox.com/docs/performance-optimization/microprofiler/task-scheduler)). The docs describe no per-script time slices.
- **Render-step code blocks the frame.** Code bound to the render step blocks rendering: "All rendering updates will wait until the code in the render step finishes", and `PreRender` work delays the frame ([`RunService.yaml`](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/RunService.yaml)).
- **Deferred work.** `task.defer`, `task.delay`, and `task.wait` resume on later steps "without throttling" ([Roblox, schedule code](https://create.roblox.com/docs/scripting/scheduler)).
- **Implication.** Roblox bounds frame impact through script authors' discipline, the watchdog, and Parallel Luau actors, not by slicing a busy script (inferred).

## 2. wasmtime

These findings come from wasmtime `main` at `08cca22` (version `52.0.0-dev`). Zed pins 48.0.7 (section 4).

### 2.1 Fuel versus epoch interruption

- **Fuel.** Fuel instruments code to count operations, and the store traps or yields when fuel runs out. Fuel is deterministic, and its accounting is imprecise only after a trap ([`config.rs` L632-L671](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L632-L671)).
- **Epochs.** An epoch is a global counter on the `Engine`. Compiled code compares it with a per-store deadline. On the deadline the store traps, calls a callback, or yields to an async executor ([`config.rs` L689-L746](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L689-L746)). `increment_epoch` is one atomic increment and is signal-safe ([`engine.rs` L926-L938](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/engine.rs#L926-L938)).
- **Cost.** Epochs are faster, "in some measurements, up to 2-3x". Use fuel only when interruption must be deterministic ([`config.rs` L790-L803](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L790-L803)). The 1.0 announcement measured SpiderMonkey.wasm "roughly twice as fast" with epochs as with fuel ([Bytecode Alliance, 2022](https://bytecodealliance.org/articles/wasmtime-10-performance)).
- **Limits of both.**
  - Neither epochs nor fuel interrupt a guest blocked in a host call ([`config.rs` L752-L765](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L752-L765)).
  - Bulk operations such as `memory.copy` check the epoch only once at their start ([`config.rs` L774-L788](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L774-L788)).
  - Epoch interruption does not work with the Winch compiler ([`config.rs` L805](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L805)).

### 2.2 Memory caps: `ResourceLimiter`

- **Scope.** A `ResourceLimiter` gates growth of linear memories and tables, and limits the number of instances, memories, and tables per store. It "does not limit 100% of memory": Wasmtime's own data structures and the embedder's allocations are not counted. CPU limits need fuel or epochs ([`limits.rs` L10-L32](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/runtime/limits.rs#L10-L32)).
- **Effect on the guest.** Refusing growth makes `memory.grow` return -1, which a guest handles as allocation failure ([`limits.rs` L50-L68](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/runtime/limits.rs#L50-L68)).

### 2.3 Cost per instance

- **Instantiation.** Instantiation of SpiderMonkey.wasm went from about 2 ms to 5 µs through copy-on-write heap images and lazy table initialization ([Bytecode Alliance, 2022](https://bytecodealliance.org/articles/wasmtime-10-performance)). The fast path uses the pooling allocator, copy-on-write images, and `InstancePre` ([wasmtime docs, fast instantiation](https://docs.wasmtime.dev/examples-fast-instantiation.html)).
- **Copy-on-write on macOS.** On Unix other than Linux, copy-on-write needs a module loaded with `Module::deserialize_file`, and the module must have been compiled with the setting on ([`config.rs` L2426-L2447](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L2426-L2447)).
- **Address space.** On 64-bit hosts each linear memory reserves 4 GiB of address space by default, so most bounds checks disappear ([`config.rs` L2074-L2083](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L2074-L2083)). This reservation is virtual. No source I found gives the resident cost of an idle store.

### 2.4 Threading

- **Engine.** An `Engine` "can be safely shared across threads and is a cheap cloneable handle" ([`engine.rs` L25](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/engine.rs#L25)).
- **Stores.** The fast-instantiation example creates one `Store` per thread and runs 100 threads against one `InstancePre` ([wasmtime docs, fast instantiation](https://docs.wasmtime.dev/examples-fast-instantiation.html)).

### 2.5 Component model and WIT

- **WIT.** WIT is an IDL that describes a component's imports and exports. A WIT package groups `interface`s and `world`s ([WIT spec, L1-L22](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/WIT.md#L1-L22)).
- **Host bindings.** wasmtime generates host bindings from WIT with `wasmtime::component::bindgen!`, which Zed uses (section 4).

### 2.6 Compile time for a reload

- **Ways to shorten compiles.** Wasmtime's docs suggest precompiling, a compilation cache, the Winch baseline compiler ("a single, quick pass", slower code), and parallel compilation, which is on by default ([`examples-fast-compilation.md`](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/docs/examples-fast-compilation.md)).
- **Incremental cache.** Cranelift can cache per-function results with `enable_incremental_compilation` ([`config.rs` L416-L429](https://github.com/bytecodealliance/wasmtime/blob/08cca2243427ac669cf384259d545ba71a9f06d2/crates/wasmtime/src/config.rs#L416-L429)).
- **No absolute numbers.** The 1.0 post gives relative gains only, such as regalloc2 building SpiderMonkey.wasm 6% faster on one thread ([Bytecode Alliance, 2022](https://bytecodealliance.org/articles/wasmtime-10-performance)). I found no primary source for the Cranelift compile time of a small component.
- **Reload chain.** A Wasm plugin reload also needs the guest compiled to Wasm first, for example with `cargo` or `swift build`. That step is outside wasmtime (inferred).

## 3. WasmKit

These findings come from WasmKit `main` at `eb7c95a`. The checked features are also in release 0.5.0, published 17 November 2026.

- **Fuel and epochs.** WasmKit now has both, as translation-time options on `EngineConfiguration`. Fuel traps when exhausted and the store stays usable. With epochs, another thread can stop a guest at function entries and loop headers ([`Engine.swift` L182-L199](https://github.com/swiftwasm/WasmKit/blob/eb7c95a4a43302aa6357dfa04788534493fa8bdb/Sources/WasmKit/Engine.swift#L182-L199)). One unit is "roughly one executed WebAssembly operator", and bulk operations cost one unit per 64 bytes ([`Store.swift` L4-L8](https://github.com/swiftwasm/WasmKit/blob/eb7c95a4a43302aa6357dfa04788534493fa8bdb/Sources/WasmKit/Execution/Store.swift#L4-L8)).
- **Resumable calls.** Fuel arrived in September 2026. `ResumableCall` followed in October 2026 and suspends a guest that runs out of fuel, so it can resume later ([PR #504](https://github.com/swiftwasm/WasmKit/pull/504)). That gives cooperative time slicing in a Swift host.
- **Memory caps.** A `ResourceLimiter` protocol gates memory and table growth ([`ResourceLimiter.swift` at 0.5.0](https://github.com/swiftwasm/WasmKit/blob/0.5.0/Sources/WasmKit/ResourceLimiter.swift)).
- **Interpreter speed.** WasmKit compares itself only with other interpreters (wasm3, stitch, wasmi) on CoreMark, and calls the result "well competitive" ([`RegisterMachine.md` L227-L237](https://github.com/swiftwasm/WasmKit/blob/eb7c95a4a43302aa6357dfa04788534493fa8bdb/Documentation/RegisterMachine.md#L227-L237)). PR #504 reports CoreMark on an M4 Max at 5,362 with direct threading, 5,006 with fuel metering, and 1,966 with token threading and fuel ([PR #504](https://github.com/swiftwasm/WasmKit/pull/504)). I found no primary comparison with wasmtime. wasmtime compiles to native code, so it should be several times faster on compute-bound guests (inferred, unmeasured).
- **Reload.** Translation is lazy by default: a function is translated "only when the first function is called" ([`Engine.swift` L120-L133, L231](https://github.com/swiftwasm/WasmKit/blob/eb7c95a4a43302aa6357dfa04788534493fa8bdb/Sources/WasmKit/Engine.swift#L120-L231)). No JIT compile sits in the reload path (inferred).
- **Embedding.** The core has no Foundation dependency and builds with Embedded Swift ([README L54-L60](https://github.com/swiftwasm/WasmKit/blob/eb7c95a4a43302aa6357dfa04788534493fa8bdb/README.md#L54-L60)).

### 3.1 Swift SDK for WebAssembly and Embedded Swift

- **The SDKs.** Since Swift 6.2, swift.org distributes Swift SDKs for Wasm. Each bundle holds a full SDK and an Embedded Swift SDK, and `swift run` can run modules with WasmKit ([swift.org, getting started](https://www.swift.org/documentation/articles/wasm-getting-started.html)). Embedded binaries are "multiple orders of magnitude smaller" (same page).
- **What Foundation lacks on WASI.** swift-corelibs-foundation turns off FoundationNetworking on WASI and treats libdispatch as unavailable there ([`CMakeLists.txt` L70-L76, L145-L146](https://github.com/swiftlang/swift-corelibs-foundation/blob/d93e9e280acd4a43519451a30208c97f37a52115/CMakeLists.txt#L70-L146)). It leaves out `Process`, `Thread`, `RunLoop`, `Timer`, `Operation`, `OperationQueue`, `NotificationQueue`, `SocketPort`, and `Progress` ([`NSObjCRuntime.swift` L313-L327](https://github.com/swiftlang/swift-corelibs-foundation/blob/d93e9e280acd4a43519451a30208c97f37a52115/Sources/Foundation/NSObjCRuntime.swift#L313-L327)). The Swift vision document names threading, file system access, networking, and localization as areas needing special support. It also says Swift Concurrency on Wasm defaults to a cooperative single-threaded executor ([vision: WebAssembly](https://github.com/swiftlang/swift-evolution/blob/main/visions/webassembly.md)).
- **What Embedded Swift lacks.** Embedded Swift drops reflection (`Mirror`), `Codable`, Objective-C interop, library evolution, and builds without whole-module optimization. Weak and unowned references are "not yet supported". Concurrency is "partial, experimental", single-threaded ([Embedded Swift status](https://docs.swift.org/embedded/documentation/embedded/status); [language subset](https://docs.swift.org/embedded/documentation/embedded/languagesubset)). The status tables do not list Foundation.

## 4. Zed

These findings come from Zed at `aa06397`, which pins wasmtime 48.0.7 ([`Cargo.toml` L995](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/Cargo.toml#L995)).

### 4.1 Extensions

- **Engine.** Zed uses one global wasmtime `Engine` with the component model, an incremental compilation cache, and epoch interruption. A background task increments the epoch every 100 ms. Zed's comment calls that interval "a rough upper bound for how long the extension execution can block" ([`wasm_host.rs` L556-L601](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_host/src/wasm_host.rs#L556-L601)).
- **Compile and run.** Zed compiles each component with `Component::from_binary` on GPUI's background executor ([`wasm_host.rs` L652-L664](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_host/src/wasm_host.rs#L652-L664)). Each extension gets its own `Store`, which yields after one epoch tick ([`wasm_host.rs` L668-L686](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_host/src/wasm_host.rs#L668-L686)). Calls arrive over a channel into a task on Tokio ([`wasm_host.rs` L700-L729](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_host/src/wasm_host.rs#L700-L729)). Host work that needs the app goes back to the main thread through `on_main_thread` ([`wasm_host.rs` L944-L972](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_host/src/wasm_host.rs#L944-L972)).
- **Cache size.** The compilation cache is capped at 32 MB, and "our extensions turn into roughly 512kb in the cache" ([`wasm_host.rs` L1014-L1016](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_host/src/wasm_host.rs#L1014-L1016)).
- **No memory limiter.** `extension_host` sets no `ResourceLimiter` (no match for `limiter` or `ResourceLimiter` under `crates/extension_host/src`).
- **WIT.** The API is versioned WIT under `crates/extension_api/wit/since_v*` ([`since_v0.8.0/extension.wit`](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/extension_api/wit/since_v0.8.0/extension.wit)). The host binds it with `wasmtime::component::bindgen!` per version.

### 4.2 GPUI at 120 FPS on macOS

- **Frame pacing.** On macOS 14 and later, GPUI paces each window with a `CAMetalDisplayLink` on its layer. Earlier systems share one immortal `CVDisplayLink` per display ([`gpui_macos/display_link.rs` L1-L5](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/gpui_macos/src/display_link.rs#L1-L5)).
- **Main thread.** The link runs on the main run loop "because GPUI renders on the foreground thread". It keeps the default `preferredFrameRateRange`, which follows the display and power policy ([`gpui_apple/display_link.rs` L47-L82](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/gpui_apple/src/display_link.rs#L47-L82)).
- **Presentation.** The Metal layer keeps three drawables ([`metal_renderer.rs` L203](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/gpui_apple/src/metal_renderer.rs#L203)). By default GPUI presents through the command buffer. It uses `presentsWithTransaction` only when native views must stay in sync ([`metal_renderer.rs` L563-L569](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/gpui_apple/src/metal_renderer.rs#L563-L569)).
- **Draw only on demand.** A frame request draws only when the window is dirty, forced, or has next-frame callbacks or pending presentation ([`window.rs` L1906, L1971](https://github.com/zed-industries/zed/blob/aa06397a1d88189b779b3c781c3e6835aa0cb888/crates/gpui/src/window.rs#L1906-L1971)).
- **Zed's own account.** 120 Hz leaves 8.33 ms per frame for state update, layout, and drawing. GPUI draws a few primitives with specialized shaders, and caches text shaping and glyph atlases ([Zed blog, 2023](https://zed.dev/blog/videogame)).

## 5. anomalyco/rune and rune-luau

These findings come from `anomalyco/rune` at `baf7c39`. The spike pinned `7615558`.

- **Scripts run on the UI thread.** Rune has no render thread yet. Input, `poll`, views, layout, animation, and paint run on the platform main thread ([`ARCHITECTURE.md` L59-L63](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/ARCHITECTURE.md#L59-L63)). A rune-luau `Script` wraps `Rc<Inner>`, so it cannot leave its thread. Its `poll` and `view` are called from the app's `poll` and `view` ([`script.rs` L64-L72](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/script.rs#L64-L72)). Off-thread work goes through `spawn_blocking`, which uses a pool of four threads shared by all scripts and returns results through a `Completer` ([`workers.rs` L1-L7, L91-L122](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/workers.rs#L1-L122)). The plan targets a separate render thread ([`PLAN.md` L30](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/PLAN.md#L30)).
- **Idle behavior.** The event loop waits with `ControlFlow::Wait` ([`event_loop.rs` L182](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune/src/window/event_loop.rs#L182)). The display link submits one drawable per tick and coasts about 150 ms after idle without waking the main thread. It paces at 60 Hz when Low Power Mode caps a ProMotion panel ([`display_link.rs` L1-L11](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune/src/platform/display_link.rs#L1-L11)). `script.poll` enters the VM only when a task deadline or a host completion is due. `script.view` is memoized on the script's version ([README L41-L43](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/README.md#L41-L43)).
- **A busy script stalls frames.** Every entry runs under the 250 ms CPU watchdog on the calling thread ([README L93-L96](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/README.md#L93-L96); [`script.rs` L309-L320](https://github.com/anomalyco/rune/blob/baf7c39c3c4442a3bab7a9a2381720ca4bee9414/crates/rune-luau/src/script.rs#L309-L320)). That thread is the UI thread, so a busy handler, task, or render can hold the frame for up to 250 ms of CPU, or 5 s of wall time when the CPU is starved. At 120 Hz that is about 30 frames (inferred).
- **Measured cost.** The rune spike ran one VM per instance. Footprint grew from 20 MB at N = 2 to 43 MB at N = 32, about 0.77 MB per instance. Threads grew from 7 to 39, and idle CPU was 10 to 30 ms per 60 s (`results.tsv`, rows `anom`). The spike notes that `Script::watch` starts one FSEvents thread per script (`gary-spike-anomaly-rune/spike/results/README.md`).

## 6. JavaScriptCore

- **Threading.** The API is thread-safe, but "all other threads attempting to use the same virtual machine must wait". To run JavaScript concurrently, "use a separate `JSVirtualMachine` instance for each thread". Values cannot cross between virtual machines ([Apple, JSVirtualMachine](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine)).
- **Timeout API.** `JSContextGroupSetExecutionTimeLimit` lives in `JSContextRefPrivate.h`, which the macOS SDK does not ship. The callback returns `true` to terminate, or `false` to grant another period ([`JSContextRefPrivate.h` L50-L95](https://github.com/WebKit/WebKit/blob/ee0d3d5011ce88e689e63f6a10d44c1655da77a8/Source/JavaScriptCore/API/JSContextRefPrivate.h#L50-L95)). JSC's watchdog arms a wall-clock timer and checks the thread's CPU time when it fires ([`Watchdog.cpp` L55-L78, L129-L137](https://github.com/WebKit/WebKit/blob/ee0d3d5011ce88e689e63f6a10d44c1655da77a8/Source/JavaScriptCore/runtime/Watchdog.cpp#L55-L137)).
- **Gary today.**
  - Gary resolves the private symbol with `dlsym` (`Sources/GaryPrivate/private.m:11`, `:55-65`).
  - Each engine has one `JSVirtualMachine` and a serial queue at `.userInitiated`, with a 100 ms CPU limit (`Sources/gary/PluginEngine.swift:7-11`, `:104-123`).
  - Bar plugins share one engine, and all other kinds share a second (`Sources/gary/PluginEngines.swift:4-15`).
  - So one busy bar plugin blocks every other bar plugin for up to 100 ms, though not the main thread (inferred).
- **Per-VM cost.** Apple documents none. Measured with Gary's two shared engines, footprint grew from 25 MB at N = 2 to 43 MB at N = 32, about 0.6 MB per instance (`results.tsv`, rows `gary`). Gary had the highest idle CPU of the four runtimes, 30 to 70 ms per 60 s. No public API caps a VM's memory.

## 7. Rendering on macOS

- **The render loop.** At 120 Hz, "the app needs to update the UI every 8.3 ms". The main thread handles the event, and the UI framework sends the new state to the render server in the Core Animation commit. The render server is a separate process that renders on the CPU, then the GPU. A late commit causes a commit hitch, and a late render server causes a render hitch. In triple-buffer mode the render server gets two intervals, but the app still gets one ([Apple, hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)).
- **Transactions.** Every layer-tree change belongs to a transaction. Implicit transactions commit "when the thread's runloop next iterates" ([Apple, CATransaction](https://developer.apple.com/documentation/quartzcore/catransaction)).
- **SwiftUI.** `View` is declared `@MainActor @preconcurrency protocol View` ([Apple, View](https://developer.apple.com/documentation/swiftui/view)), so `body` runs on the main thread. Built-in animatable effects such as `scaleEffect` run "off the main thread and without calling into any of your view code". A custom `Animatable` conformance "will run body for every frame of the animation" ([WWDC23, Explore SwiftUI animation](https://developer.apple.com/videos/play/wwdc2023/10156/)).
- **Display links on macOS 14 and later.** `NSView.displayLink(target:selector:)` (macOS 14.0) calls back in sync with the view's display, and not while the view is hidden ([Apple](<https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)>)). `CAMetalDisplayLink` (macOS 14.0) adds control over the frame-rate range and latency for Metal layers, and runs on whatever run loop it is added to ([Apple, CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink)). `CAMetalLayer` presents asynchronously to Core Animation transactions unless `presentsWithTransaction` is set ([Apple](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)).
- **What must stay on the main thread.** `NSView` and `NSCell` are main-thread-only, and the main thread handles events. A secondary thread may draw into a locked view, or create a window ([Apple, Thread Safety Summary](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html)). SwiftUI `body` is main-actor bound (above). Metal command encoding is not on this list. Rune and GPUI still encode on the main thread (sections 4 and 5).

## 8. macOS scheduling

- **QoS on Apple silicon.** QoS decides priority and, on Apple silicon, the core type: background work is "more likely" to run on efficiency cores. Apple recommends QoS APIs over `pthread_setschedparam`, `setpriority`, or `thread_set_policy` ([Apple, tuning for Apple silicon](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon)).
- **QoS to priority.** User-interactive maps to base priority 46, user-initiated to 37, utility to 20, and background to 4 ([`thread_policy.c` L84-L90](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/thread_policy.c#L84-L90); [`sched.h` L160-L166](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/sched.h#L160-L166)).
- **Clutch scheduler.** The scheduler picks a QoS bucket by earliest deadline. Worst-case execution latency is 0 for FG, 37.5 ms for IN, 75 ms for DF, 150 ms for UT, and 250 ms for BG ([`sched_clutch.c` L199-L206](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/sched_clutch.c#L199-L206)). Higher buckets get a "warp" (FG 8 ms, UT 1 ms) to jump ahead in bursts ([L223-L230](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/sched_clutch.c#L223-L230)). When the deadline order picks a lower bucket, it gets a starvation-avoidance window of one thread quantum ([design doc L57](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/doc/scheduler/sched_clutch_edge.md#L57)).
- **Quanta on macOS.** FG, IN, and DF get 10 ms, UT 4 ms, and BG 2 ms ([`sched_clutch.c` L240-L249](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/sched_clutch.c#L240-L249)).
- **How far QoS shields the UI thread.** QoS bounds delay only when cores are saturated. Even then, a utility thread holds a core for at most about one 4 ms quantum, and a user-initiated thread for 10 ms (inferred from the tables above). The Edge scheduler on multi-cluster chips places threads per QoS and moves high-QoS work to clusters with lower scheduling latency ([design doc L177, L222-L228](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/doc/scheduler/sched_clutch_edge.md#L177-L228)). No source puts a number on main-thread latency under plugin load.
- **Per-process controls.** `taskpolicy(8)` can start a program with a QoS clamp (`-c utility|background|maintenance`), a memory limit in MiB (`-m`), `PRIO_DARWIN_BG` (`-b`), or throughput and latency tiers. It can also change a running process (`-p`) (`man 8 taskpolicy`, macOS 27.2.1). `PRIO_DARWIN_BG` sets the lowest scheduling priority and throttles disk and network I/O (`man 2 setpriority`).
- **Cost of a process per plugin.** Measured: `/bin/sleep` has a 1.1 MB footprint. The whole Odin bar was 11 to 21 MB, and the whole Rust plus rune-rs bar 14 to 17 MB, each with a window (`results.tsv`). I did not measure a minimal Swift or Rust helper, or XPC round-trip latency. I found no primary source for either.

## 9. Native hot reload of dylibs

- **`dlclose`.** `dlclose` never unloads a library linked by the main executable, one in the shared cache, one with thread-local variables, or one with Objective-C classes (`man 3 dlclose`, macOS 27.2.1).
- **Swift too.** dyld's policy is stricter than the man page: "images with ObjC or Swift are never unloaded except MH_BUNDLE _without_ Swift" ([`MachOAnalyzer.cpp` L2829-L2842](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/common/MachOAnalyzer.cpp#L2829-L2842)). A Swift plugin dylib stays mapped after every reload. A reload must load a fresh copy under a new path, and old code and globals leak (inferred).
- **The Odin spike.** The Odin spike loads its own copy of the `.dylib` per instance (`tmp/lang-spike/scale-spec.md`). A native plugin has no CPU or memory cap and shares the address space (inferred).

## 10. Comparison of plugin runtimes

| Runtime                 | Reload latency                                                                                 | CPU cap mechanism                                                       | Memory cap mechanism                                                | Per-instance cost                                                                                       | Threading                                                                    |
| ----------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Luau (rune-luau / mlua) | 0.54 to 1.04 ms measured; ≤ 5 ms gate; compile ~950K lines/s                                   | Interrupt at safepoints, host checks thread CPU time; C calls unbounded | Per-VM allocator, exact for Luau heap only                          | ~0.77 MB measured (with rune state)                                                                     | One thread at a time per VM; VMs on any threads; rune-luau pins to UI thread |
| wasmtime                | Cranelift compile plus guest toolchain build; no primary number; instantiation µs with pooling | Epochs (async yield or trap) or fuel (deterministic, ~2x slower)        | `ResourceLimiter` on linear memory and tables, not host allocations | 4 GiB virtual reservation per memory; resident cost not found                                           | `Engine` shared; one `Store` per thread at a time                            |
| WasmKit                 | Lazy translation, no JIT; plus guest toolchain build                                           | Fuel or epochs; `ResumableCall` suspends on out-of-fuel                 | `ResourceLimiter` on memory and tables                              | Not measured                                                                                            | Interpreter on the calling thread; epochs stoppable from another thread      |
| JavaScriptCore          | Script evaluation; not measured here                                                           | Private `JSContextGroupSetExecutionTimeLimit`, CPU-checked              | None public                                                         | ~0.6 MB measured (shared VMs); ~3.5 MB measured with one VM per plugin (129 MB at N = 32, `GaryVM.app`) | One thread per VM at a time; concurrency needs one VM per thread             |
| Native dylib            | Rebuild plus `dlopen` of a new copy; Swift and ObjC images never unload                        | None in process                                                         | None in process                                                     | Odin: ~0.33 MB measured                                                                                 | Any thread; full address space                                               |
| Process per plugin      | Process restart plus runtime start                                                             | QoS clamp, `PRIO_DARWIN_BG`, kernel scheduler                           | `taskpolicy -m`, kernel-enforced                                    | ≥ 1.1 MB (C floor); Swift and Rust helpers not measured                                                 | Own threads; IPC to the shell                                                |

Per-instance costs come from `results.tsv` as (footprint at N = 32 minus footprint at N = 2) / 30. They include each spike's own host state, so they compare runtimes only roughly.

## 11. What the sources imply for 120 FPS under plugin load

All of this section is inferred.

1. **The renderer matters less than where plugin code runs.** Apple's frame budget is one 8.3 ms interval on the main thread, in every buffering mode. Every runtime's stop mechanism works on a 100 ms to 250 ms scale: Gary's JavaScriptCore limit, rune-luau's watchdog, and Zed's epoch tick. Only work that never runs on the main thread is safe. Rune's current model runs Luau on the UI thread, so a busy script drops frames by design.
2. **Plugins should hand the main thread data, not code.** A plugin runs on a worker and produces a view tree or diff. The main thread applies it and commits. Zed has the same split: extensions run on Tokio and reach the app only through `on_main_thread` messages.
3. **Use the CPU-time budget for runaways and slices for fairness.** Luau's interrupt and wasmtime's epochs can both stop a VM at a safepoint from a budget held by the host. To keep one busy plugin from starving others on a shared worker, the host needs a short slice, such as a few ms per entry, or one thread per busy plugin. Gary today shares one bar engine, so plugins delay each other.
4. **Keep plugin workers below user-interactive QoS, and fewer than the P-cores.** The main thread runs at user-interactive (FG bucket, priority 46). Plugin threads at utility then hold a core for at most a 4 ms quantum, even when cores are saturated, and are more likely to run on E-cores. Gary's engine queue today runs at user-initiated, which gets 10 ms quanta.
5. **Memory caps differ by layer.** Luau and wasmtime can cap the script heap exactly but not host-side allocations. Only a process boundary gives a kernel-enforced cap (`taskpolicy -m`) and a QoS clamp per plugin. It costs at least 1.1 MB per plugin plus IPC.
6. **Fastest reload: Luau, then WasmKit, then wasmtime.** Luau compiles in about a millisecond, and its swap keeps hot state. WasmKit translates lazily but still needs the guest's own build. wasmtime adds a Cranelift compile, softened by Zed's incremental cache. Native dylibs leak every reload in a Swift host.
7. **On macOS, rune-luau and Gary run interpreters.** rune-luau turns native Luau code off on macOS, and Gary ships with the hardened runtime and no `allow-jit` entitlement. Plugin code should therefore be light per frame, and heavy work should move to host functions on workers.

## 12. Open questions

1. **Luau VM floor.** What does an empty Luau VM cost with Gary's bindings but without rune's UI state? The 0.77 MB per instance includes rune-side memo and element state.
2. **Swift binding.** Would a Swift core call Luau's C API through a small C shim, or would a Rust core use mlua? How much host-call overhead does each add per render?
3. **JavaScriptCore per-VM cost.** Answered after this note was drafted: `GaryVM.app`, which gives every plugin its own `PluginEngine` and `JSVirtualMachine`, measured 129 MB footprint, 146 MB peak, and 200 ms CPU per minute at N = 32, against 42 MB, 56 MB, and 70 ms for today's shared VMs. That is about 3.5 MB per plugin (measured, one 60 s run).
4. **Cranelift compile time.** How long does a typical plugin component take to compile, cold and with the incremental cache? No primary source gives this.
5. **wasmtime under the hardened runtime.** Does it need `com.apple.security.cs.allow-jit` or `allow-unsigned-executable-memory` in a notarized Gary? I found no wasmtime documentation on this.
6. **Process per plugin.** What are the footprint of a minimal Swift and a minimal Rust helper, and the XPC round-trip latency at 120 Hz update rates? Neither is measured or documented.
7. **Main-thread latency under load.** With N utility-QoS plugin threads spinning on an M-series Mac, does main-thread scheduling latency stay under 1 ms? The XNU tables bound it in theory, but only a test with `os_signpost` and Instruments' Hitches template can say.
8. **SwiftUI or Metal for the bar.** Does a SwiftUI bar with 32 widgets updating once per second, plus one widget animating, stay hitch-free at 120 Hz? Or does it need a Metal renderer paced by `CAMetalDisplayLink`, as GPUI uses? This needs a spike.
9. **Roblox's VM layout.** Does Roblox run one VM per actor? Its public docs do not say, and the answer would show how Roblox isolates parallel scripts.

## Conflicting evidence

- **XNU quanta.** The clutch design doc lists 8 ms for IN and 6 ms for DF. The code uses 10 ms for both on macOS, and the doc's values only on other targets ([doc L93-L112](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/doc/scheduler/sched_clutch_edge.md#L93-L112); [`sched_clutch.c` L240-L258](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/sched_clutch.c#L240-L258)). This note uses the code.
- **Cost of fuel.** wasmtime puts fuel at roughly 2 to 3 times slower than epochs, while WasmKit measured only 7% overhead with direct threading (5,362 to 5,006). The engines differ: one compiles to native code, the other interprets. The numbers do not transfer.
- **Luau GC pauses.** The same page says the collector "rarely" causes visible pauses, but also that the atomic step can pause for "tens of milliseconds" ([Luau, performance](https://luau.org/performance)).
- **Native Luau.** Luau's docs list JIT for arm64, but rune-luau enables it only on Windows and Linux and gives no reason for leaving out macOS. The hardened runtime is a plausible cause (inferred).
- **Zed's epoch bound.** Zed calls 100 ms "a rough upper bound". wasmtime notes that bulk memory operations check the epoch only once, so a large `memory.copy` can run longer.

## Sources inspected locally

| Repository                | Revision                                                | Local path                                                |
| ------------------------- | ------------------------------------------------------- | --------------------------------------------------------- |
| sndrgrdn/gary             | `2445588` (clean tree)                                  | `/Users/sander/Developer/gary`                            |
| anomalyco/rune            | `baf7c39c3c4442a3bab7a9a2381720ca4bee9414`              | `~/.cache/checkouts/github.com/anomalyco/rune`            |
| luau-lang/luau            | `97b2f4bf9cd935bed666f3e643a3b749b4d22f38`              | `~/.cache/checkouts/github.com/luau-lang/luau`            |
| mlua-rs/mlua              | `cbd45a79ffdcf424314eaf43b51dcb6807ef5297` (v0.12.3)    | `~/.cache/checkouts/github.com/mlua-rs/mlua`              |
| bytecodealliance/wasmtime | `08cca2243427ac669cf384259d545ba71a9f06d2` (52.0.0-dev) | `~/.cache/checkouts/github.com/bytecodealliance/wasmtime` |
| swiftwasm/WasmKit         | `eb7c95a4a43302aa6357dfa04788534493fa8bdb`              | `~/.cache/checkouts/github.com/swiftwasm/WasmKit`         |
| zed-industries/zed        | `aa06397a1d88189b779b3c781c3e6835aa0cb888`              | `~/.cache/checkouts/github.com/zed-industries/zed`        |

The local spike results come from `tmp/lang-spike/scale/results.tsv` and `~/Developer/gary-spike-anomaly-rune/spike/results/README.md` at `21d6c8e`.

These were fetched as single files rather than cloned:

- WebKit `ee0d3d5`: `JSContextRefPrivate.h` and `Watchdog.cpp`.
- xnu `f6217f8`: `sched_clutch.c`, `sched.h`, `thread_policy.c`, and `doc/scheduler/sched_clutch_edge.md`.
- dyld `fd8d0c4`: `common/MachOAnalyzer.cpp`.
- swift-corelibs-foundation `d93e9e2`: `CMakeLists.txt` and `NSObjCRuntime.swift`.
- component-model `585526a`: `design/mvp/WIT.md`.
- WasmKit `0.5.0`: `Engine.swift` and `ResourceLimiter.swift`.
