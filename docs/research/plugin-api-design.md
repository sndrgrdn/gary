# Plugin authoring API: prior art and three shapes for Gary

Research note, November 2026. It surveys how Cloudflare Workers, Vercel, Raycast, Quickshell, Übersicht, VS Code, Vite, and Nuxt shape their authoring surfaces, then sketches three authoring APIs for Gary.

Sections 1 to 3 hold findings, each backed by a source. Section 4 holds inference: the three API shapes, their tradeoffs, and a recommendation. Section 5 lists open questions.

## 1. Gary today

These findings come from the local tree at `df07f2d` in `/Users/sander/Developer/gary` and from `~/Developer/gary-plugins` at `008a8da`.

- **Entry files are scripts, not modules.** The guide tells authors to assign `module.exports`, because `import`, `export`, and `require` fail (`Sources/gary/SkillGuide.swift:95`). The runtime predefines `module` and `exports` before it evaluates the file (`Sources/gary/PluginRuntime.swift:306`). It reads the exports lazily through `m.exports` and requires a `render` function for every kind except `service` (`Sources/gary/PluginScripts.swift:21-22`).
- **Sucrase runs only its TypeScript transform.** The call is `transforms: ["typescript"], disableESTransforms: true` (`Sources/gary/TypeScript.swift:41`). The vendored bundle is sucrase 3.35.1 (`scripts/vendor-sucrase.sh:5`). That bundle also contains the `imports` and `jsx` transforms (`Resources/vendor/sucrase.js` includes `jsxRuntime`, `jsxPragma`, and `"imports"`).
- **The manifest drives the loader before any code runs.** Gary installs `host` functions only for the capabilities in `uses` (`Sources/gary/PluginRuntime.swift:300-303`). `subscribes` selects which topics run and appear in `state`. `hotkeys` and `keepLoaded` live in the manifest too (`SkillGuide.swift:126-141`). `gary plugin install` prints each plugin's capabilities and their macOS permissions from the manifest before it asks for consent (`Sources/gary/PluginCommand.swift:213-238`). `gary plugin validate` loads only the manifest and checks that each entry point exists (`PluginCommand.swift:147-157`).
- **Types come from the manifest through code generation.** "`gary.d.ts` declares only what the manifest asks for" (`SkillGuide.swift:55`). Authors rerun `gary plugin types` after each change to `uses` or `subscribes` (`SkillGuide.swift:75`). A capability topic's type is merged into `Gary.State` only when the plugin subscribes to it, as the clock capability does (`Sources/gary/Capabilities/Clock.swift:5-9`). A plugin topic is typed `Json`, so a consumer must parse it by hand. For example, `"example.disk"?: Json` (`examples/disk/gary.d.ts:158`) forces `parseDisk` in `examples/disk/widget.ts`.
- **`onTopic` is not discriminated.** Its signature is `onTopic?(topic: string, value: Json, state: State)` (`examples/disk/gary.d.ts:191-201`), so `value` never narrows by topic.
- **Kinds are isolated.** "Each kind runs in its own JavaScriptCore context from its own entry file, so kinds share no variables" (`SkillGuide.swift:40`).
- **Render model.** Gary runs the entry file once, then calls `render(state)` once per display after every handler, timer, host callback, and topic change. A call over 100 ms stops the plugin (`SkillGuide.swift:59`). Module-level variables hold state (`SkillGuide.swift:98`).
- **No sandbox.** The install warning says plugins run unsandboxed with the user's access (`PluginCommand.swift:214-217`). So `uses` shapes the API surface and the consent review. It does not confine the code.
- **Scale of a migration.** 17 entry files assign `module.exports`: 6 plugins in `gary-plugins` and 7 bundled examples. The largest plugin, `sndrgrdn.theme`, has about 1,240 lines.
- **Public JavaScriptCore has no module loader.** The macOS SDK's JavaScriptCore headers declare no `JSScript` and no module API. They offer `evaluateScript` and `JSCheckScriptSyntax` (`$(xcrun --show-sdk-path)/System/Library/Frameworks/JavaScriptCore.framework/Headers/JSContext.h:81`, `JSBase.h:125`). Native ESM therefore needs a source transform, such as sucrase's `imports`.

## 2. Prior art

### 2.1 Cloudflare Workers

**Module shape.** A Worker's default export is an object of handlers: `export default { fetch(request, env, ctx), scheduled(controller, env, ctx) }` ([migration guide](https://developers.cloudflare.com/workers/reference/migrate-to-module-workers/)). The `ExportedHandler<Env, ...>` interface lists the optional handlers `fetch`, `scheduled`, `queue`, `email`, `tail`, and others. Each handler type takes `(event, env: Env, ctx: ExecutionContext)` ([workers-types 5.20261121.1 `index.d.ts`, lines 447-509](https://unpkg.com/@cloudflare/workers-types@5.20261121.1/index.d.ts)).

**Inference without annotations.** The docs write `export default { async fetch(req, env, ctx) {...} } satisfies ExportedHandler<Env>`, with no parameter annotations ([RPC TypeScript](https://developers.cloudflare.com/workers/runtime-apis/rpc/typescript/)). `satisfies` checks the object against the type without widening it ([TS 4.9](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-9.html#the-satisfies-operator)). Gary already uses the same pattern with `satisfies Gary.BarWidget`.

**Manifest versus code.** Bindings live in the Wrangler config. `wrangler types` generates `worker-configuration.d.ts` with an `Env` interface built from the bindings, the compatibility date, and the flags. It must be rerun after config changes, and `--check` fails CI when the file is stale ([TypeScript docs](https://developers.cloudflare.com/workers/languages/typescript/)). The runtime types declare an empty `Cloudflare.Env` for projects to merge into. They also declare a `GlobalProps.mainModule` hook, which lets types flow from the code's exports back into `ctx.exports` ([`index.d.ts` lines 16164-16199](https://unpkg.com/@cloudflare/workers-types@5.20261121.1/index.d.ts)). For a service binding, `wrangler types -c a -c b` reads the other Worker's config and source, so `env.WORKER_B` has `Service<import("../b/src/index").SumService>` as its type ([RPC TypeScript](https://developers.cloudflare.com/workers/runtime-apis/rpc/typescript/)). This is the same direction as `gary plugin types`: config in, `.d.ts` out.

**Capabilities as a parameter, not globals.** In the service-worker format, bindings were globals. In module format, they arrive only through `env` ([migration guide](https://developers.cloudflare.com/workers/reference/migrate-to-module-workers/)). Cloudflare explains that globals "magically appear in your code". It calls `env` "more secure" because "you can control which modules and libraries get access to your environment variables", which keeps a third-party library from enumerating secrets ([blog, 2021](https://blog.cloudflare.com/workers-javascript-modules/)). Later, Cloudflare added `import { env } from "cloudflare:workers"` for top-level access, so the ergonomics pulled back towards a global ([migration guide](https://developers.cloudflare.com/workers/reference/migrate-to-module-workers/); `export const env: Cloudflare.Env` at [`index.d.ts` line 16464](https://unpkg.com/@cloudflare/workers-types@5.20261121.1/index.d.ts)).

**Why they left `addEventListener`.** The migration guide gives these reasons:

1. Speed. Global bindings force "a new JavaScript execution context" per request, and modules reuse it.
2. Durable Objects require modules.
3. Newer bindings such as D1, AI, and Workflows exist only for modules.
4. Gradual deployments need modules.
5. Module Workers can be published to npm.

New features may skip the service-worker format ([migration guide](https://developers.cloudflare.com/workers/reference/migrate-to-module-workers/)). The original announcement adds that modules give standard `import` and `export`, and that a default export replaces registering handlers by event name ([blog](https://blog.cloudflare.com/workers-javascript-modules/)).

**Classes for stateful entrypoints.** `WorkerEntrypoint<Env, Props>` and `DurableObject<Env, Props>` are abstract classes with `protected ctx` and `protected env`, plus optional handler methods (`fetch`, `alarm`, `webSocketMessage`, and others). Their public methods become RPC methods ([`index.d.ts` lines 16222-16263](https://unpkg.com/@cloudflare/workers-types@5.20261121.1/index.d.ts); [DO base class](https://developers.cloudflare.com/durable-objects/api/base/)). Calls are always asynchronous on the caller's side. Functions and `RpcTarget` instances cross as stubs ([RPC](https://developers.cloudflare.com/workers/runtime-apis/rpc/)). A file can hold several entrypoints as named exports next to the default export ([RPC](https://developers.cloudflare.com/workers/runtime-apis/rpc/)).

**State.** A Durable Object's state is instance fields and `ctx.storage`. A stateless Worker has no state model beyond the reused isolate ([DO base class](https://developers.cloudflare.com/durable-objects/api/base/)).

### 2.2 Vercel

**Typed config file.** `vercel.ts` replaces `vercel.json`. It "executes at build time". Its final rules must sit in a `config` export typed `VercelConfig` from `@vercel/config/v1`, with helpers such as `routes.rewrite(...)` ([vercel.ts docs](https://vercel.com/docs/project-configuration/vercel-ts)). The CLI imports the module and collects its default export and `export const` values ([`packages/config/src/cli.ts` L23-L36](https://github.com/vercel/vercel/blob/155eacfa16840e68ae54bc50ee72fc8e16733857/packages/config/src/cli.ts#L23-L36)). Project-level config is therefore code that Vercel runs.

**Functions as named exports.** A file under `/api` exports one function per HTTP method, such as `export function GET(request: Request)`. A file can instead export a default `{ fetch }` object, the same shape as Workers ([Functions API](https://vercel.com/docs/functions/functions-api-reference)). The path determines routing, so the file system is the manifest.

**Per-function config in the code, read statically.** `export const config = { runtime, maxDuration, regions }` configures one function ([Functions API](https://vercel.com/docs/functions/functions-api-reference)). Vercel reads it without running the file. `@vercel/static-config` parses the source with Oxc, falling back to ts-morph. It finds `export const config`, accepts only literals, arrays, and objects, unwraps `as` and `satisfies`, and rejects spreads and identifiers. It then validates the result against a JSON schema ([`static-config/src/index.ts` L63, L235-L253, L289-L326](https://github.com/vercel/vercel/blob/155eacfa16840e68ae54bc50ee72fc8e16733857/packages/static-config/src/index.ts#L235-L326)). Next.js uses the same idea in its route segment config: options are "directly exporting the following variables" ([Next.js](https://nextjs.org/docs/app/api-reference/file-conventions/route-segment-config)).

**Takeaway.** Vercel uses both approaches. Project config is executed. Per-function metadata is extracted statically from a literal-only export, so the platform can know a function's runtime and limits before it runs the code.

### 2.3 Raycast: the closest analogue

**Manifest.** `package.json` is "a superset of npm's `package.json`". It lists `commands`, each with `name`, `title`, `mode` (`view`, `no-view`, or `menu-bar`), an optional background `interval`, `arguments`, and `preferences`. "The name directly maps to the entry point file", so `index` maps to `src/index.ts(x)` ([manifest](https://developers.raycast.com/information/manifest)). Raycast has one entry file per command, like Gary's one file per kind.

**Module shape.** "If the extension exports a default function, this function will automatically be called. If you return a React component … it will automatically be rendered as the root component." A no-view command exports an async function ([lifecycle](https://developers.raycast.com/information/lifecycle)). A menu-bar command, the nearest thing to a Gary bar widget, returns `<MenuBarExtra>` ([menu bar](https://developers.raycast.com/api-reference/menu-bar-commands)).

**Types from the manifest.** Preference types are "autogenerated in `raycast-env.d.ts` when you run the extension" as a global `Preferences` namespace, so `getPreferenceValues<Preferences.ShowTodos>()` "stay[s] in sync with the manifest" ([preferences](https://developers.raycast.com/api-reference/preferences)). Arguments work the same way through `LaunchProps<{ arguments: Arguments.ShowTodos }>` ([arguments](https://developers.raycast.com/information/lifecycle/arguments)). The base declaration is generic with a default: `getPreferenceValues<Values extends PreferenceValues = PreferenceValues>(): Values` ([`@raycast/api@2.13.1` types, L4988-L5002](https://unpkg.com/@raycast/api@2.13.1/types/index.d.ts)). This is the same codegen direction as Gary.

**State and reactivity.** State lives in React state and hooks. `useCachedPromise(fn, args, options)` returns `{ data, isLoading, error, revalidate, mutate }`, serves stale data from a cache that "will be kept between command runs", and reruns when `args` change ([useCachedPromise](https://developers.raycast.com/utilities/react-hooks/usecachedpromise)).

**Lifecycle.** Menu-bar commands "are not long-lived processes". Raycast loads one, renders it, waits for `isLoading` to become `false`, then unloads it, and reloads it on the `interval` or on a click ([menu bar](https://developers.raycast.com/api-reference/menu-bar-commands)). Gary differs: a bar widget stays loaded.

**Capabilities.** Raycast has none in its manifest. Each extension runs in its own V8 isolate in a shared Node process. It talks to Raycast over "a defined set of APIs", but extensions "are not further sandboxed" for files, network, or Node ([security](https://developers.raycast.com/information/security)).

**A real example.** `menubar-weather` declares one `menu-bar` command with `"interval": "30m"` and typed dropdown, textfield, and checkbox preferences ([`package.json` L14-L43](https://github.com/raycast/extensions/blob/d0cd72a2a83719a8a8ef93633655b93b0df1b254/extensions/menubar-weather/package.json#L14-L43)). The command is `export default function MenubarWeather()`, which uses custom hooks and returns `<MenuBarExtra isLoading={isLoading} …>` ([`menubar-weather.tsx` L19-L58](https://github.com/raycast/extensions/blob/d0cd72a2a83719a8a8ef93633655b93b0df1b254/extensions/menubar-weather/src/menubar-weather.tsx#L19-L58)). Its fetch hook wraps `useCachedPromise(fn, [kLocation], { keepPreviousData: true })` ([`useLatestWeather.ts` L19-L27](https://github.com/raycast/extensions/blob/d0cd72a2a83719a8a8ef93633655b93b0df1b254/extensions/menubar-weather/src/hooks/useLatestWeather.ts#L19-L27)). The extension also depends on `axios` and `react`, which npm supplies. Gary has no npm.

### 2.4 Quickshell

**No manifest.** A config is a directory with `shell.qml` ([`parsecommand.cpp` L25-L32](https://github.com/quickshell-mirror/quickshell/blob/9b0f339b19057f4731bf3b48293307d7ef241671/src/launch/parsecommand.cpp#L25-L32)). Launch-time settings come from `//@ pragma` comments in the root file, scanned line by line before QML loads: `Env`, `AppId`, `ShellId`, `DataDir`, and others ([`launch.cpp` L88-L125](https://github.com/quickshell-mirror/quickshell/blob/9b0f339b19057f4731bf3b48293307d7ef241671/src/launch/launch.cpp#L88-L125)). This is code-embedded metadata that the host reads statically.

**Capabilities are imported types.** Authors instantiate objects such as `SystemClock { precision: SystemClock.Seconds }` and `Process { command: [...]; stdout: StdioCollector {...} }` ([`clock.hpp` L10-L46](https://github.com/quickshell-mirror/quickshell/blob/9b0f339b19057f4731bf3b48293307d7ef241671/src/core/clock.hpp#L10-L46); [`process.hpp` L23-L33](https://github.com/quickshell-mirror/quickshell/blob/9b0f339b19057f4731bf3b48293307d7ef241671/src/io/process.hpp#L23-L33)). A capability exists while its object exists. Nothing declares it ahead of time, and nothing sandboxes it.

**Reactivity.** QML property bindings: "When a property's dependencies change in value, the property is automatically updated", because the engine tracks the binding's dependencies ([Qt property binding](https://doc.qt.io/qt-6/qtqml-syntax-propertybinding.html)). `text: Qt.formatDateTime(clock.date, ...)` re-evaluates on each `dateChanged`. There is no render function. This is fine-grained reactivity, whereas Gary rebuilds the whole tree.

### 2.5 Übersicht

Each widget is one `.jsx` file of named exports: `command`, `refreshFrequency`, `render`, `className`, `initialState`, `updateState(event, previousState)`, and `init(dispatch)`. Simple state comes from the command's output. Richer state comes from a Redux-like `updateState`. There is no manifest, and ESM imports from `lib/` or `src/` are allowed ([README L6-L16, L18-L170](https://github.com/felixhageloh/uebersicht/blob/859a7d70525949b8bdeec19d69a4766678ca3527/README.md#L6-L170)). The metadata (`refreshFrequency`, `command`) lives in the code, and the host reads it by running the module.

### 2.6 VS Code, briefly

`package.json` declares `contributes` and `activationEvents`. The main module exports `activate()`, which VS Code calls "only once" when a matching event fires, and an optional `deactivate()` ([activation events](https://code.visualstudio.com/api/references/activation-events)). Since VS Code 1.74, contributed commands, views, and languages no longer need a matching `onCommand:`, `onView:`, or `onLanguage:` entry, because VS Code derives the activation from `contributes` ([same page](https://code.visualstudio.com/api/references/activation-events)). The lesson: they removed declarations that duplicated other parts of the manifest.

### 2.7 `define*` helpers, briefly

Vite's `defineConfig` is an identity function with overloads. It is a "type helper" whose body is `return config` ([`config.ts` L189-L202](https://github.com/vitejs/vite/blob/3567471998e3da315675086f44368e266c9c0e33/packages/vite/src/node/config.ts#L189-L202)). Its only job is contextual typing, which is what `satisfies` gives without a helper.

Nuxt's `definePageMeta` is "a compiler macro": a call in the page's code that the build reads as route metadata ([Nuxt](https://nuxt.com/docs/4.x/api/utils/define-page-meta)).

TypeScript 5.0 `const` type parameters infer literal tuples such as `["clock", "session"]` without `as const` ([TS 5.0](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-0.html#const-type-parameters)). TypeScript 5.4 `NoInfer<T>` stops a position from widening an inferred type parameter ([TS 5.4](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-4.html#the-noinfer-utility-type)). Together they let a `define*` call infer `state` from its `subscribes` field. Section 4.2 shows a sketch that passes type checking.

## 3. Comparison

| System | Metadata lives in | Capabilities typed by | Module shape | State and reactivity |
| --- | --- | --- | --- | --- |
| Gary today | `manifest.json` | `gary plugin types` from the manifest | `module.exports = {...} satisfies Gary.X`, one file per kind | Module `let`, full re-render after every event |
| Cloudflare | `wrangler.jsonc` | `wrangler types` from config, plus imported code types for RPC | `export default {...} satisfies ExportedHandler<Env>`, or classes | Isolate reuse; DO fields and `ctx.storage` |
| Vercel | File path, `export const config` (static), `vercel.ts` (executed) | `VercelConfig` from a package | Named `GET`/`POST` exports or default `{ fetch }` | None (request-scoped) |
| Raycast | `package.json` commands | `raycast-env.d.ts` from the manifest | `export default function Command()` returning JSX, one file per command | React hooks; loaded on demand, then unloaded |
| Quickshell | `//@ pragma` lines, no manifest | QML types | Declarative QML object tree | Fine-grained property bindings |
| Übersicht | Named exports in code | None | Named exports in one `.jsx` | `updateState` reducer |
| VS Code | `package.json` contributes | `@types/vscode` | `export function activate(context)` | Imperative, through disposables |

Patterns that recur:

1. **Platforms that gate capabilities keep the declaration in static config.** Cloudflare, Raycast, and VS Code all declare in config and generate or ship types. When code carries the metadata, the host extracts it without running anything: Vercel's literal-only extractor and Quickshell's pragma scanner both work this way.
2. **The default export is the handler object, and `satisfies` provides the types.** Cloudflare and Vercel converged on `export default { fetch }`. Raycast uses `export default function` because its unit is a React component.
3. **Capabilities move from ambient globals to parameters, then partly back.** Cloudflare moved bindings from globals to `env` for control and security, then added an importable `env` for convenience.
4. **Generated `.d.ts` files need a staleness check.** Cloudflare added `wrangler types --check` for CI. Raycast regenerates its file whenever the extension runs.

## 4. Three shapes for Gary (inference)

Everything in this section is inference. Each shape rewrites `sndrgrdn.weather/widget.ts`, which subscribes to `clock` and `session` and uses `network`. The `parse` and `icons` helpers stay as they are.

### 4.1 Shape A: ESM `export default`, manifest unchanged

```ts
let weather: Weather | null = null;
let attempted = 0;
let locked = false;

export default {
  onTopic(topic, _value, state) {
    if (topic === "session") {
      if (locked && !state.session?.locked) setTimeout(() => refresh(state), 10_000);
      locked = state.session?.locked ?? false;
    } else if (Date.now() - attempted >= interval) refresh(state);
  },
  render: () => ({
    type: "row",
    gap: 8,
    children: [
      { type: "image", key: "icon", path: `icons/${weather?.icon ?? "cloud"}.png`, width: 19, height: 18, y: -1 },
      { type: "text", key: "temperature", text: weather?.temperature ?? "--°C", color: weather ? "foreground" : "dark_foreground" },
    ],
  }),
} satisfies Gary.BarWidget;
```

**Loader change.** Add sucrase's `imports` transform, which "Transforms ES Modules … to CommonJS" ([sucrase README L80-L86](https://github.com/alangpierce/sucrase/blob/280ee202e73b18e396069782bd41e1eaaccbf620/README.md#L80-L86)). Change the export reader in `PluginScripts.swift:21` to `m.exports.default ?? m.exports`. Gary can keep accepting `module.exports`. To allow imports between files inside the plugin folder, Gary would need a small `require` that resolves relative paths inside the folder, the way Übersicht treats `lib/` and `src/`. Without it, an `import` of a local file fails at load.

**Static validation.** Unchanged, since the manifest is still the source of truth.

**Per-kind files.** Unchanged.

**Typing `state` from `subscribes`.** Unchanged: generated `gary.d.ts`. The generator could also emit a discriminated `onTopic`, such as `onTopic?(...a: { [K in Subscribed]: [K, Topics[K], State] }[Subscribed])`, so `value` narrows by topic. It could also type plugin topics from the publisher's declared shape instead of `Json`.

**Migration.** A mechanical codemod: `module.exports =` becomes `export default`. Both forms can coexist indefinitely.

**Tradeoffs.** It looks like Cloudflare's `ExportedHandler` and matches what TypeScript users expect. It is the cheapest change. It does not reduce the duplication between the manifest and the code, and it keeps the `gary plugin types` step.

### 4.2 Shape B: `Gary.widget({...})` with typed topics, manifest fields optionally in code

```ts
let weather: Weather | null = null;
let attempted = 0;
let locked = false;

export default Gary.widget({
  subscribes: ["clock", "session"],
  topics: {
    clock(_clock, state) {
      if (Date.now() - attempted >= interval) refresh(state.settings);
    },
    session(session, state) {
      if (locked && !session.locked) setTimeout(() => refresh(state.settings), 10_000);
      locked = session.locked;
    },
  },
  render: () => ({ type: "row", gap: 8, children: [/* as in shape A */] }),
});
```

`Gary.widget`, `Gary.panel`, `Gary.service`, and so on would be identity functions that Gary predefines, as Vite's `defineConfig` is. No import is needed, and no npm. The typing that lets `subscribes` drive `state` and the `topics` handlers fits in a few lines:

```ts
type StateOf<T extends Topic> = BaseState & { [K in T]?: Topics[K] };
interface WidgetSpec<T extends Topic> {
  subscribes?: readonly T[];
  topics?: { [K in NoInfer<T>]?: (value: Topics[K], state: StateOf<NoInfer<T>>) => void };
  render(state: StateOf<NoInfer<T>>): Node;
}
declare function widget<const T extends Topic = never>(spec: WidgetSpec<T>): WidgetSpec<T>;
```

I checked a version of this with `deno check` (TypeScript 6.0.3) in a scratch file outside the repository. `state.clock` resolved to `Clock | undefined`, and the `session` handler's parameter resolved to `Session`. Reading `state.battery` was an error, and so was a `session` handler without `"session"` in `subscribes`. Without `NoInfer`, a key in `topics` would silently add itself to `T`.

`host` remains a problem. A global `host` cannot narrow per call. To keep "only the declared capabilities", either keep generating `host` from the manifest, as today, or pass it in: `setup({ host }) { ...; return { render, topics } }`. Cloudflare took the parameter route with `env`. It costs a level of nesting and closes module-level state over `setup`.

**Where the manifest lives.** There are three variants, and B2 is the one I recommend:

- **B1, manifest stays canonical.** `subscribes` in code exists only for types, and `gary plugin validate` checks that it matches the manifest. This keeps the duplication but makes a mismatch an error.
- **B2, code is canonical, read statically.** The loader extracts literal `uses`, `subscribes`, `hotkeys`, and `keepLoaded` from the `Gary.widget({...})` argument, the way `@vercel/static-config` does: literals only, no spreads or identifiers. Gary would need a parser for this. Sucrase exposes only `transform`, `getFormattedTokens`, and `getVersion` ([`src/index.ts` L30-L76](https://github.com/alangpierce/sucrase/blob/280ee202e73b18e396069782bd41e1eaaccbf620/src/index.ts#L30-L76)), so Gary would have to write a small literal extractor. `manifest.json` keeps `id`, `name`, `version`, `kinds`, and the entry files. The install review keeps working without running code.
- **B3, code is canonical, read by running it.** Gary evaluates the file with a stub `host` to collect the spec, as Vercel runs `vercel.ts` and Übersicht reads its exports. This is the simplest to build, but top-level side effects such as `setInterval` or `fetch` run during the read, and the install review would have to execute untrusted code.

**Per-kind files versus one file.** The same `define*` helpers allow one file with `export const widget = Gary.widget(...)` and `export const panel = Gary.panel(...)`, like Cloudflare's named entrypoints. Gary would still evaluate the file once per kind in separate contexts. A module-level `let` would then look shared but would not be, which makes this a trap. I would keep one file per kind unless kinds start to share a context.

**Migration.** Mostly mechanical. `onTopic` bodies that switch on `topic` split into `topics` entries, and `subscribes` and `uses` move or are copied into code. Keep accepting shape A and today's form.

**Tradeoffs.** Better inference with no codegen for `state` and topics, and a typed handler per topic. It also fixes the `Json` plugin topics, if publishers declare their topic type in code and consumers import that type. The costs are a second export style to document, and, for B2, a static extractor in Swift or JavaScript.

### 4.3 Shape C: JSX component plus hooks

```tsx
export default function Weather() {
  const session = Gary.useTopic("session");
  const { latitude = 53.2, longitude = 5.8 } = Gary.useSettings();
  const weather = Gary.useFetch(
    `https://api.open-meteo.com/v1/forecast?latitude=${latitude}&longitude=${longitude}&current=temperature_2m,weather_code`,
    parse,
    { every: 15 * 60_000, pause: session?.locked, retryAfterResume: 10_000 },
  );
  return (
    <row gap={8}>
      <image key="icon" path={`icons/${weather.data?.icon ?? "cloud"}.png`} width={19} height={18} y={-1} />
      <text key="temperature" color={weather.data ? "foreground" : "dark_foreground"}>
        {weather.data?.temperature ?? "--°C"}
      </text>
    </row>
  );
}
```

**Loader change.** Add sucrase's `jsx` transform with `jsxRuntime: "classic"` and `jsxPragma` set to a Gary node factory ([README L136-L150](https://github.com/alangpierce/sucrase/blob/280ee202e73b18e396069782bd41e1eaaccbf620/README.md#L136-L150)). The factory returns today's JSON nodes, and a `JSX.IntrinsicElements` declaration in `gary.d.ts` types the props. I checked that typing with `deno check` too: an unknown prop and an unsubscribed `useTopic` key were both errors.

Hooks need a runtime: slot storage per component instance, effects, and re-render scheduling. Gary already re-renders after every callback, which helps. Two harder problems remain:

- `render` runs once per display (`SkillGuide.swift:59`). Hook state per display would issue one fetch per display unless the hooks share a cache keyed by arguments, as `useCachedPromise` does.
- Inline handlers (`onClick={() => …}`) would need Gary to assign action ids per render and route `onAction` back to closures. Without that, authors keep string `action` names.

**Static validation.** As in shape A or B. Hooks cannot declare capabilities. `useTopic("x")` could be checked against `subscribes` at type level, as in the sketch, but not at load time without parsing.

**Per-kind files.** One component per kind file, like Raycast's one command per file.

**Migration.** A rewrite, not a codemod. Shapes A and B would have to remain supported.

**Tradeoffs.** It is the most familiar API for Raycast and Übersicht authors, and declarative data such as `useFetch(..., { every })` removes hand-written timers and the `attempted` bookkeeping. It is also the largest runtime addition (Gary has no npm, so it would ship its own hook runtime), it has the per-display identity problem, and it moves away from "render is pure; state is module variables". Raycast's hooks suit a load, render, and unload lifecycle. Gary's widgets stay loaded, so module state is already a reasonable store.

### 4.4 Summary

| | A: ESM default | B: `Gary.widget` | C: JSX and hooks |
| --- | --- | --- | --- |
| Loader change | Add `imports` transform, read `.default` | A, plus predefined identity helpers, plus a literal extractor for B2 | A, plus `jsx` transform, node factory, hook runtime, closure actions |
| Static validation | Manifest, as today | B1: manifest. B2: literal extraction. B3: requires running code | As A or B |
| `state` from `subscribes` | Codegen, as today | Inferred from the call, no codegen | Codegen or inferred, per hook |
| Per-kind files | Unchanged | Unchanged; one file possible but misleading | Unchanged |
| Migration | Codemod | Codemod plus splitting `onTopic` | Rewrite |

My recommendation is A now, then B with B2 as the next step. A takes a few lines in `TypeScript.swift` and `PluginScripts.swift` and gives authors standard ESM. B2 removes the `gary plugin types` round trip for `state` and keeps the install review static. Treat C as a separate project, revisited only if authors ask for declarative data hooks; a `Gary.poll`/`Gary.fetchEvery` helper inside shape B may cover most of that need.

## 5. Open questions

1. **Can the install review rely on code?** If metadata moves into code (B2 or B3), does `gary plugin install` accept a literal-only extraction, or must `manifest.json` keep `uses` and `hotkeys`?
2. **Who writes the extractor?** A literal-only extractor in Swift, a small JS parser bundled like sucrase, or a different vendored transform that exposes an AST?
3. **Imports between plugin files.** Should Gary resolve relative `import` within a plugin folder? It needs a module cache and path confinement like the `image` path rule.
4. **Typed plugin topics.** Can a publisher declare its topic type once (for example `export type Topic = {...}` in its service file) so consumers get it instead of `Json`? This needs `gary plugin types` to read another plugin's source, like `wrangler types -c ../other`.
5. **`host` as a global or a parameter.** Narrowing `host` per capability without codegen requires passing it in. Is the nesting worth it, given that `uses` does not sandbox anything?
6. **Stale types.** Should `gary plugin validate` or `gary doctor` fail when `gary.d.ts` is stale, as `wrangler types --check` does?
7. **Multi-surface modules.** How do `surface` and `surfaces` map onto `Gary.panel({...})`, and onto JSX if shape C goes ahead?

## Sources inspected locally

| Repository | Revision | Local path |
| --- | --- | --- |
| sndrgrdn/gary | `df07f2d` (clean tree) | `/Users/sander/Developer/gary` |
| sndrgrdn/gary-plugins | `008a8da` | `/Users/sander/Developer/gary-plugins` |
| vercel/vercel | `155eacfa16840e68ae54bc50ee72fc8e16733857` | `~/.cache/checkouts/github.com/vercel/vercel` |
| quickshell-mirror/quickshell | `9b0f339b19057f4731bf3b48293307d7ef241671` | `~/.cache/checkouts/github.com/quickshell-mirror/quickshell` |
| felixhageloh/uebersicht | `859a7d70525949b8bdeec19d69a4766678ca3527` | `~/.cache/checkouts/github.com/felixhageloh/uebersicht` |
| alangpierce/sucrase | `280ee202e73b18e396069782bd41e1eaaccbf620` (package.json 3.35.1) | `~/.cache/checkouts/github.com/alangpierce/sucrase` |

These were fetched as single files rather than cloned:

- `@cloudflare/workers-types@5.20261121.1` and `@raycast/api@2.13.1`, from unpkg.
- `raycast/extensions` at `d0cd72a2`, `extensions/menubar-weather`, from raw.githubusercontent.com.
- Vite `config.ts` at `3567471`.
