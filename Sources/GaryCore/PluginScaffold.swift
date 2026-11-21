import Foundation

public enum PluginScaffold {
    public static func files(id: PluginID, kinds: [PluginKind]) -> [String: String] {
        let name = id.rawValue.split(separator: ".").last!.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        let entries = kinds.map { "\"\($0.rawValue)\": \"\(entryFile($0))\"" }.joined(separator: ", ")
        var files = [
            "manifest.json": """
            {
              "$schema": "./\(PluginTypes.schemaFile)",
              "schemaVersion": \(PluginManifest.schemaVersion),
              "id": "\(id)",
              "name": "\(name)",
              "version": "0.1.0",
              "kinds": [\(kinds.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))],
              "entryPoints": { \(entries) },
              "subscribes": [],
              "uses": []
            }

            """,
            "tsconfig.json": """
            {
              "compilerOptions": {
                "strict": true,
                "noEmit": true,
                "target": "es2023",
                "lib": ["es2023"],
                "types": [],
                "moduleDetection": "force",
                "isolatedModules": true
              }
            }

            """,
            "README.md": """
            # \(name)

            A Gary plugin: \(kinds.map(\.rawValue).joined(separator: ", ")).

            ## Install

            ```sh
            gary plugin add <git-url> --enable
            ```

            ## Develop

            Gary reloads the plugin each time you save an entry file. Type-check it with `npx -p typescript tsc -p .`.
            After you change `uses` or `subscribes` in `manifest.json`, run `gary plugin types .` to refresh `\(PluginTypes.declarationsFile)`.

            """,
        ]
        for kind in kinds {
            files[entryFile(kind)] = source(kind, name: name)
        }
        return files
    }

    public static func entryFile(_ kind: PluginKind) -> String {
        switch kind {
        case .barWidget: "widget.ts"
        case .bar, .panel, .overlay, .menu, .service: "\(kind.rawValue).ts"
        }
    }

    private static func source(_ kind: PluginKind, name: String) -> String {
        switch kind {
        case .barWidget:
            """
            let clicks = 0;

            module.exports = {
              render() {
                return { type: "text", text: "\(name) " + clicks, style: "active", action: "click" };
              },
              onAction(action) {
                if (action === "click") clicks += 1;
              },
            } satisfies Gary.BarWidget;

            """
        case .bar:
            """
            module.exports = {
              render(state) {
                return {
                  type: "row",
                  padding: 8,
                  children: [
                    { type: "text", key: "name", text: "\(name)", style: "active" },
                    { type: "spacer", key: "gap" },
                    { type: "text", key: "display", text: state.display ? state.display.width + "×" + state.display.height : "" },
                  ],
                };
              },
            } satisfies Gary.Bar;

            """
        case .panel:
            """
            let count = 0;

            module.exports = {
              surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

              render() {
                return {
                  type: "column",
                  style: "panel",
                  gap: 8,
                  children: [
                    { type: "text", key: "title", text: "\(name)", style: "title" },
                    {
                      type: "button",
                      key: "add",
                      action: "add",
                      hover: "hover",
                      padding: 4,
                      children: [{ type: "text", text: "Pressed " + count + " times" }],
                    },
                  ],
                };
              },

              onAction(action) {
                if (action === "add") count += 1;
              },
            } satisfies Gary.Panel;

            """
        case .overlay:
            """
            module.exports = {
              render() {
                return {
                  type: "column",
                  background: "alpha(background, 0.6)",
                  action: "close",
                  children: [
                    { type: "spacer", key: "top" },
                    { type: "text", key: "title", text: "\(name): click to close", style: "title" },
                    { type: "spacer", key: "bottom" },
                  ],
                };
              },

              onAction(action) {
                if (action === "close") host.hide();
              },
            } satisfies Gary.Overlay;

            """
        case .menu:
            """
            const choices = ["One", "Two", "Three"];
            let selected = 0;

            module.exports = {
              render() {
                return {
                  type: "column",
                  style: "panel",
                  children: choices.map((choice, index) => ({
                    type: "text",
                    key: choice,
                    text: choice,
                    style: index === selected ? "selected" : "default",
                    action: "pick:" + index,
                  })),
                };
              },

              onKey(key) {
                if (key === "down") selected = (selected + 1) % choices.length;
                if (key === "up") selected = (selected + choices.length - 1) % choices.length;
                if (key === "enter") pick(selected);
              },

              onAction(action) {
                if (action.startsWith("pick:")) pick(Number(action.slice(5)));
              },
            } satisfies Gary.Menu;

            function pick(index: number) {
              host.log("picked " + choices[index]);
              host.hide();
            }

            """
        case .service:
            """
            let ticks = 0;

            setInterval(() => {
              ticks += 1;
              host.publish({ ticks });
            }, 60_000);
            host.publish({ ticks });

            module.exports = {
              methods: {
                ticks: () => String(ticks),
              },
            } satisfies Gary.Service;

            """
        }
    }
}
