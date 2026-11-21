import Foundation

public enum PluginTypes {
    public static let declarationsFile = "gary.d.ts"
    public static let schemaFile = "manifest.schema.json"

    public static func declarations(capabilities: [String], pluginTopics: [PluginID], theme: JSON?) -> String {
        func names(_ section: String) -> String {
            let keys = theme?[section]?.object?.keys.sorted() ?? []
            return (keys.map { "\"\($0)\"" } + ["(string & {})"]).joined(separator: " | ")
        }
        func union(_ values: [String]) -> String { values.map { "\"\($0)\"" }.joined(separator: " | ") }
        let style = (StyleProps.numbers.map { "\($0.0)?: number;" } + [
            "padding?: number | [number, number] | [number, number, number, number];", "offset?: number;",
            "align?: \(union(Align.allCases.map(\.rawValue)));",
        ] + StyleProps.colors.map { "\($0.0)?: Color;" } + ["font?: FontName;"])
            .map { "    \($0)" }.joined(separator: "\n")
        let nodes = Node.Kind.allCases.map { kind in
            "  interface \(typeName(kind.rawValue)) extends Style {\n    type: \"\(kind.rawValue)\";\(fields(kind).map { "\n    \($0)" }.joined())\n  }"
        }.joined(separator: "\n")
        let modules = PluginKind.allCases.map { "  type \(typeName($0.rawValue)) = \($0 == .service ? "Module" : "Rendered");" }.joined(separator: "\n")
        let topics = pluginTopics.map { "    \"\($0)\"?: Json;" }.joined(separator: "\n")
        return """
        declare namespace Gary {
          type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
          type Kind = \(union(PluginKind.allCases.map(\.rawValue)));
          type Key = "up" | "down" | "enter" | "escape" | "tab";
          type StyleName = \(names("styles"));
          type FontName = \(names("fonts"));
          type ColorName = \(names("colors"));
          type Color = ColorName;

          interface Style {
            key?: string;
            style?: StyleName;
            action?: string;
        \(style)
          }
        \(nodes)
          type Node = \(Node.Kind.allCases.map { typeName($0.rawValue) }.joined(separator: " | "));

          interface Display {
            id: string;
            index: number;
            main: boolean;
            width: number;
            height: number;
            notched: boolean;
            notch: { left: number; right: number } | null;
          }
          interface Theme {
            mode: "light" | "dark";
            colors: { [name: string]: string };
            palette: { [name: string]: string };
          }
          interface State {
            settings: { [key: string]: Json };
            theme: Theme;
            display?: Display;
        \(topics)
          }

          type Edges<T> = { top?: T; bottom?: T; left?: T; right?: T };
          interface Surface {
            screen?: "main" | "focused" | "all" | number;
            anchors?: Edges<boolean>;
            width?: number | "fit";
            height?: number | "fit";
            margins?: number | Edges<number>;
            layer?: \(union(SurfaceLayer.allCases.map(\.rawValue)));
            exclusionMode?: "normal" | "ignore";
            clickThrough?: boolean;
            focusable?: boolean;
            background?: \(union(SurfaceBackground.allCases.map(\.rawValue)));
          }

          type ActionPayload = null | number | string;
          interface Storage {
            get(key: string): Json | undefined;
            set(key: string, value: Json | undefined): void;
          }
          interface Host {
            log(message: string): void;
            storage: Storage;
            publish(value: Json): void;
            show(): void;
            hide(): void;
            toggle(): void;
          }

          interface Module {
            render?(state: State): Node;
            onAction?(action: string, payload: ActionPayload, state: State): void;
            onKey?(key: Key, state: State): void;
            onHotkey?(id: string, state: State): void;
            onTopic?(topic: string, value: Json, state: State): void;
            methods?: { [name: string]: (...args: string[]) => Json | void };
            surface?: Surface | null | ((state: State) => Surface | null | undefined);
          }
          interface Rendered extends Module {
            render(state: State): Node;
          }
        \(modules)
        }

        declare const host: Gary.Host;
        declare var module: { exports: Gary.Module };
        declare var exports: Gary.Module;
        declare function setTimeout(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
        declare function setInterval(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
        declare function clearTimeout(id?: number): void;
        declare function clearInterval(id?: number): void;
        \(capabilities.map { $0 + "\n" }.joined())
        """
    }

    public static func manifestSchema(_ capabilities: CapabilityNames) -> JSON {
        func strings(_ values: [String]) -> String { JSON.array(values.map(JSON.string)).text }
        let kinds = strings(PluginKind.allCases.map(\.rawValue))
        return try! JSON.parse(#"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Gary plugin manifest",
          "type": "object",
          "required": ["schemaVersion", "id", "name", "version", "kinds", "entryPoints"],
          "$defs": {
            "id": { "type": "string", "maxLength": 128, "pattern": "^[a-z0-9][a-z0-9-]*(\\.[a-z0-9][a-z0-9-]*)+$" }
          },
          "properties": {
            "$schema": { "type": "string" },
            "schemaVersion": { "const": \#(PluginManifest.schemaVersion) },
            "id": { "allOf": [{ "$ref": "#/$defs/id" }, { "not": { "type": "string", "pattern": "^gary\\." } }] },
            "name": { "type": "string" },
            "version": { "type": "string" },
            "kinds": { "type": "array", "minItems": 1, "uniqueItems": true, "items": { "enum": \#(kinds) } },
            "entryPoints": {
              "type": "object",
              "propertyNames": { "enum": \#(kinds) },
              "additionalProperties": { "type": "string", "pattern": "^(?![/~])(?!.*(^|/)\\.{0,2}(/|$))[^\\u0000]*\\.(js|ts)$" }
            },
            "keepLoaded": { "type": "boolean" },
            "subscribes": {
              "type": "array",
              "items": { "anyOf": [{ "enum": \#(strings(capabilities.topics.sorted())) }, { "$ref": "#/$defs/id" }] }
            },
            "uses": { "type": "array", "items": { "enum": \#(strings(capabilities.uses.sorted())) } },
            "hotkeys": {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["id", "keys"],
                "properties": {
                  "id": { "type": "string", "minLength": 1 },
                  "keys": { "type": "string", "pattern": "^(([A-Za-z]+\\+)+[^+]+|[Ff]([1-9]|1[0-2]))$" }
                }
              }
            }
          }
        }
        """#)
    }

    static func typeName(_ raw: String) -> String {
        raw.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private static func fields(_ kind: Node.Kind) -> [String] {
        switch kind {
        case .row, .column: return ["children?: Node[];"]
        case .scroll: return ["children?: Node[];", "reveal?: string;"]
        case .button: return ["children?: Node[];", "hover?: StyleName;"]
        case .text: return ["text: string | number;"]
        case .icon: return ["symbol: string;"]
        case .image: return ["path: string;"]
        case .slider, .progress: return ["value: number;"]
        case .input: return ["value?: string | number;", "placeholder?: string;", "change?: string;", "submit?: string;"]
        case .spacer: return []
        }
    }
}
