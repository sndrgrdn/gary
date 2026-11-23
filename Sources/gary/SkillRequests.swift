import Foundation

extension Skill {
    static let findPlugin = """
    ## Find the plugin the user means

    Decide where to work from the request before you change anything. `gary listPlugins` shows what runs now, and `gary plugin list` shows each plugin's source in its fifth column.

    - **A new plugin.** Build it in `~/.config/gary/plugins/<id>`. Pick an id that no plugin in `gary plugin list` has, with the prefix that the user's own plugins share, or ask the user for one.
    - **A plugin that runs now, such as "my clock" or "the weather widget".** Match the request to an id in `gary listPlugins`, and ask the user when several match. Then check its source in `gary plugin list`:
    	- A folder path, with `local` in the last column: the plugin is in `~/.config/gary/plugins` or in a local package, a folder the user owns. Edit it there.
    	- `git:` or `npm:`: Gary keeps a managed copy in `~/Library/Application Support/Gary/packages`, and `gary plugin update` replaces it. Read the plugin there, but don't edit it. Ask the user whether to change their own clone of the package, installed as a local folder in place of the `git:` or `npm:` source, or to copy the plugin into `~/.config/gary/plugins` under a new id and disable the original.
    	- `builtin`: the plugin ships inside `Gary.app`. Disable it with `gary plugin disable <id>`, and build a replacement under a new id.
    - **The bar's layout, or which widgets show.** Edit `bar` in `~/.config/gary/shell.json`, as [Add, move, or remove a widget in the bar](#add-move-or-remove-a-widget-in-the-bar) describes.
    - **Colors, fonts, or spacing everywhere.** Edit the theme, as [Change the colors, fonts, or spacing](#change-the-colors-fonts-or-spacing) describes.

    When two plugins share an id, the first one loads: built-in plugins, then `~/.config/gary/plugins`, then packages in the order `shell.json` lists them. `gary plugin list` prints the others as `invalid`.
    """

    static let commonRequests = """
    ## Common requests

    ### Show a command's output in the bar

    Scaffold from the `load` example, which runs a command with `host.exec` on a timer and shows its output:

    ```sh
    gary plugin new you.uptime --from load
    ```

    Change the command and the timer in `widget.ts`. Keep `"uses": ["exec"]` in the manifest. `gary skill show effect` shows the same pattern with `gary:effect`.

    ### Open a panel from a bar widget

    Give one plugin both kinds, and toggle the panel from the widget in `widget.tsx`:

    ```tsx
    export default {
      render(state) {
        return <text action="open">{state.nowplaying?.track?.title ?? "Nothing playing"}</text>;
      },
      onAction(action) {
        if (action === "open") host.toggle();
      },
    } satisfies Gary.BarWidget;
    ```

    The manifest has `"kinds": ["bar-widget", "panel"]`, an entry point for each, and `"subscribes": ["nowplaying"]`, so the panel's `panel.tsx` reads `state.nowplaying` too.

    ### Build a keyboard-driven menu

    A launcher or picker is a `menu` that covers the display with a `backdrop` surface, so a click outside the card hides it. An `input` takes typed text, `onKey` gets the arrows, and `hoverAction` moves the selection to the row under the pointer. The `launcher` example is a complete app launcher with a manifest hotkey, so start from it with `gary plugin new you.launcher --from launcher`. Its core:

    ```tsx
    let query = "";
    let selected = 0;
    const items = ["Safari", "Mail", "Notes"];
    const shown = () => items.filter((item) => item.toLowerCase().includes(query.toLowerCase()));

    export default {
      surface: { anchors: { top: true, bottom: true, left: true, right: true }, exclusionMode: "ignore", background: "backdrop" },
      render: () => (
        <column key="card" width={480} style="picker" padding={8}>
          <input key="query" value={query} placeholder="Search" change="filter" submit="open" />
          {shown().map((item, index) => (
            <row key={item} action={`pick:${item}`} hoverAction={`hover:${index}`} style={index === selected ? "highlight" : undefined}>
              <text>{item}</text>
            </row>
          ))}
        </column>
      ),
      onKey(key) {
        if (key === "down") selected = Math.min(selected + 1, shown().length - 1);
        else if (key === "up") selected = Math.max(selected - 1, 0);
        else return false;
        return true;
      },
      onAction(action, payload) {
        if (action === "filter" && typeof payload === "string") {
          query = payload;
          selected = 0;
        } else if (action.startsWith("hover:") && payload === true) {
          selected = Number(action.slice(6));
        } else if (action === "open" || action.startsWith("pick:")) {
          host.hide();
        }
      },
    } satisfies Gary.Menu;
    ```

    Escape hides a menu unless `onKey` takes it. Test it with `gary key`, `gary hover`, and `gary click` on empty space, as [Test like the user](#test-like-the-user) describes.

    ### Open a surface with a shortcut from settings

    A manifest hotkey is fixed. To read the keys from settings, register them while the plugin runs with `host.hotkeys`, in a `service` so they work before the menu first loads. The `shortcuts` example does this to open apps. The manifest has `"kinds": ["service", "menu"]` and `"uses": ["hotkeys"]`, and the menu's `methods` has `open: () => host.show()`:

    ```ts
    import { Effect, Stream, host, settings } from "gary:effect";

    const keys = typeof settings.key === "string" ? settings.key : "alt+space";

    export default {
      effect: host.hotkeys([keys]).pipe(
        Stream.runForEach(() => host.call({ kind: "menu" }, "open")),
        Effect.catchTag("HostError", (error) => host.log(`${keys}: ${error.message}`)),
      ),
    } satisfies Gary.Service;
    ```

    The user sets the keys in `shell.json` as `"settings": { "you.launcher": { "key": "cmd+space" } }`, and Gary reloads the plugin. `gary key you.launcher cmd+space` presses the hotkey. Gary logs keys that another app already holds, and leaves them unregistered.

    ### Share a value between plugins

    One plugin calls `host.publish(value)`. Another lists the first plugin's id in `subscribes` and reads `state["you.source"]`. Declare the value's type in a `topic.ts` at the root of the publishing plugin, so the subscriber's `gary.d.ts` types it. `gary skill show plugin` covers `host.publish` and `state`.

    ### Fetch data from the web

    Scaffold from the `weather` example, which fetches JSON with `fetch` from `gary:effect`, decodes it with `Schema`, refreshes on a schedule and after an unlock, and reads its parameters from settings:

    ```sh
    gary plugin new you.weather --from weather
    ```

    Keep `"uses": ["network"]` in the manifest. Read API keys and other user values from `settings`, never from the source, and tell the user which settings to set in `shell.json`.

    ### Use a capability that needs a permission

    `gary skill show <capability>` names the macOS permission a capability needs. Until the user grants it, the capability's topic has `available: false` with the cause in `reason`, and its functions fail with an error that names the permission. Render that state, such as "Allow Screen Recording", instead of an empty view. Ask the user to grant the permission in the window that `gary onboarding` opens. Only the user can approve it. Screen Recording and Full Disk Access can need a restart of Gary, which that window offers. Report what you could not check while the permission was missing.

    ### Change an existing plugin

    Find the plugin's id and its source as [Find the plugin the user means](#find-the-plugin-the-user-means) describes, and edit it only where that section says. Keep its id, so its settings, its storage, and its place in the bar stay. Save, and Gary reloads it. Refresh the types with `gary plugin types <folder>` when you change `uses` or `subscribes`.

    ### Add, move, or remove a widget in the bar

    The bar's layout is `bar` in `~/.config/gary/shell.json`, not a plugin. `gary plugin enable <id>` adds a bar widget to the end of the section its manifest's `bar` field names, and `gary plugin disable <id>` turns a plugin off. To move or reorder widgets, edit the id lists in `bar.left`, `bar.center`, `bar.right`, and `bar.notchLeft`. Naming any section replaces the default sections, so list `gary.clock` and `gary.battery` if the user wants to keep them. Gary applies a saved `shell.json` at once and logs the fields it ignores. Check that no widget shows `not-in-bar` in `gary listPlugins`, compare the widgets' `x` positions in `gary tree <id>/bar-widget`, and run `gary doctor`.

    ### Change the colors, fonts, or spacing

    Change the theme, not each plugin. Put only the keys that change in `~/.config/gary/theme.json`, which Gary merges over its built-in theme: `colors`, `styles`, `fonts`, `spacing`, `radius`, and `bar`. Put palette colors in `~/.config/gary/palette.toml`, one `name = "#rrggbb"` line each, with `mode = "light"` or `"dark"`. Gary applies a saved file at once. `gary skill show theme` lists the theme's styles, colors, and fonts. A theme switcher plugin may write `palette.toml`, so check the user's plugins before you edit it, or the plugin overwrites the change. Read the drawn colors in `gary tree`, and run `gary doctor` for values that do not resolve.

    ### Install plugins from a package

    Ask the user before you install a package from someone else. `gary plugin install <source>` prints each plugin's capabilities and permissions, so show them to the user. It enables every plugin in the package and adds bar widgets to the end of their sections. Turn off the ones the user does not want with `gary plugin disable <id>`. `gary plugin update` updates packages later, and a pinned version or tag stays put.
    """
}
