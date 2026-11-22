import Foundation

public enum PluginScaffold {
    public static func files(id: PluginID, kinds: [PluginKind]) -> [String: String] {
        let name = displayName(id)
        var files = [
            "manifest.json": manifest(id: id, name: name, kinds: kinds),
            "tsconfig.json": tsconfig,
            "README.md": readme(name: name, kinds: kinds),
        ]
        for kind in kinds {
            files[entryFile(kind)] = source(kind, name: name)
        }
        return files
    }

    static func displayName(_ id: PluginID) -> String {
        id.rawValue.split(separator: ".").suffix(1).flatMap { $0.split(separator: "-") }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func manifest(id: PluginID, name: String, kinds: [PluginKind]) -> String {
        let entries = kinds.map { "\"\($0.rawValue)\": \"\(entryFile($0))\"" }.joined(separator: ", ")
        return """
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

        """
    }

    private static let tsconfig = """
    {
      "compilerOptions": {
        "strict": true,
        "noEmit": true,
        "target": "es2023",
        "lib": ["es2023"],
        "module": "preserve",
        "jsx": "react",
        "jsxFactory": "Gary.h",
        "jsxFragmentFactory": "Gary.Fragment",
        "types": [],
        "moduleDetection": "force",
        "isolatedModules": true
      }
    }

    """

    private static func readme(name: String, kinds: [PluginKind]) -> String {
        """
        # \(name)

        A Gary plugin: \(kinds.map(\.rawValue).joined(separator: ", ")).

        ## Install

        ```sh
        gary plugin install git:<host>/<owner>/<repo>
        ```

        ## Develop

        Gary reloads the plugin each time you save a file in its folder. Type-check it with `npx -p typescript tsc -p .`.
        After you change `uses` or `subscribes` in `manifest.json`, run `gary plugin types .` to refresh `\(PluginTypes.declarationsFile)`.

        """
    }

    public static func entryFile(_ kind: PluginKind) -> String {
        switch kind {
        case .barWidget: "widget.tsx"
        case .bar, .panel, .overlay, .menu: "\(kind.rawValue).tsx"
        case .service: "service.ts"
        }
    }

    private static func source(_ kind: PluginKind, name: String) -> String {
        switch kind {
        case .barWidget: widgetSource(name: name)
        case .bar: barSource(name: name)
        case .panel: panelSource(name: name)
        case .overlay: overlaySource(name: name)
        case .menu: menuSource
        case .service: serviceSource
        }
    }

    private static func widgetSource(name: String) -> String {
        """
        let clicks = 0;

        export default {
          render() {
            return (
              <text style="active" action="click">
                \(name) {clicks}
              </text>
            );
          },
          onAction(action) {
            if (action === "click") clicks += 1;
          },
        } satisfies Gary.BarWidget;

        """
    }

    private static func barSource(name: String) -> String {
        """
        export default {
          render(state) {
            return (
              <row padding={8}>
                <text key="name" style="active">
                  \(name)
                </text>
                <spacer key="gap" />
                <text key="display">{state.display ? `${state.display.width}×${state.display.height}` : ""}</text>
              </row>
            );
          },
        } satisfies Gary.Bar;

        """
    }

    private static func panelSource(name: String) -> String {
        """
        let count = 0;

        export default {
          surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

          render() {
            return (
              <column style="panel" gap={8}>
                <text key="title" style="title">
                  \(name)
                </text>
                <button key="add" action="add" hover="hover" padding={4}>
                  <text>Pressed {count} times</text>
                </button>
              </column>
            );
          },

          onAction(action) {
            if (action === "add") count += 1;
          },
        } satisfies Gary.Panel;

        """
    }

    private static func overlaySource(name: String) -> String {
        """
        export default {
          render() {
            return (
              <column background="alpha(background, 0.6)" action="close">
                <spacer key="top" />
                <text key="title" style="title">
                  \(name): click to close
                </text>
                <spacer key="bottom" />
              </column>
            );
          },

          onAction(action) {
            if (action === "close") host.hide();
          },
        } satisfies Gary.Overlay;

        """
    }

    private static let menuSource = """
    const choices = ["One", "Two", "Three"];
    let selected = 0;

    export default {
      render() {
        return (
          <column style="panel">
            {choices.map((choice, index) => (
              <text key={choice} style={index === selected ? "selected" : "default"} action={`pick:${index}`}>
                {choice}
              </text>
            ))}
          </column>
        );
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

    private static let serviceSource = """
    let ticks = 0;

    setInterval(() => {
      ticks += 1;
      host.publish({ ticks });
    }, 60_000);
    host.publish({ ticks });

    export default {
      methods: {
        ticks: () => String(ticks),
      },
    } satisfies Gary.Service;

    """
}
