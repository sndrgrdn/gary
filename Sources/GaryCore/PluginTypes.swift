import Foundation

public enum PluginTypes {
    public static let declarationsFile = "gary.d.ts"
    public static let schemaFile = "manifest.schema.json"

    public static func declarations(capabilities: [String], pluginTopics: [PluginID], theme: JSON?) -> String {
        [coreTypes(theme: theme), stateTypes(pluginTopics: pluginTopics), moduleTypes(capabilities: capabilities)].joined(separator: "\n\n")
    }

    private static func union(_ values: [String]) -> String {
        values.map { "\"\($0)\"" }.joined(separator: " | ")
    }

    private static func names(_ section: String, in theme: JSON?) -> String {
        let keys = theme?[section]?.object?.keys.sorted() ?? []
        return (keys.map { "\"\($0)\"" } + ["(string & {})"]).joined(separator: " | ")
    }

    private static var styleFields: String {
        (StyleProps.numbers.map { "\($0.0)?: number;" } + [
            "padding?: number | [number, number] | [number, number, number, number];",
        ] + StyleProps.signed.map { "\($0.0)?: number;" } + [
            "align?: \(union(Align.allCases.map(\.rawValue)));", "animation?: \(union(Animation.allCases.map(\.rawValue)));",
            "material?: \(union(Material.allCases.map(\.rawValue)));", "colorScheme?: \(union(ColorScheme.allCases.map(\.rawValue)));",
            "transition?: \(union(Transition.allCases.map(\.rawValue)));",
            "fit?: \(union(ImageFit.allCases.map(\.rawValue)));", "clip?: boolean;",
            "shadow?: { color: Color; radius?: number; y?: number };", "border?: { color: Color; width?: number };",
            "blend?: \(union(Blend.allCases.map(\.rawValue)));",
            "loop?: { " + Loop.Property.allCases.map { "\($0.rawValue)?: [number, number]; " }.joined() + "duration?: number; reverse?: boolean };",
            "background?: Paint;",
        ] + StyleProps.colors.map { "\($0.0)?: Color;" } + ["font?: FontName;"])
            .map { "    \($0)" }.joined(separator: "\n")
    }

    private static func coreTypes(theme: JSON?) -> String {
        let nodes = Node.Kind.allCases.map { kind in
            "  interface \(typeName(kind.rawValue)) extends Style {\n    type: \"\(kind.rawValue)\";\(fields(kind).map { "\n    \($0)" }.joined())\n  }"
        }.joined(separator: "\n")
        return """
        declare namespace Gary {
          type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
          type Kind = \(union(PluginKind.allCases.map(\.rawValue)));
          type Key = \(union(Set(KeyName.named.values).sorted())) | (string & {});
          interface ScrollEvent {
            x: number;
            y: number;
            precise: boolean;
            phase: "began" | "changed" | "ended" | "momentum" | "none";
            action?: string;
          }
          type StyleName = \(names("styles", in: theme));
          type FontName = \(names("fonts", in: theme));
          type ColorName = \(names("colors", in: theme));
          type Color = ColorName;
          type Paint = Color | { gradient: \(union(Gradient.Kind.allCases.map(\.rawValue))); colors: [Color, Color, ...Color[]]; angle?: number };

          interface StyleProps {
        \(styleFields)
          }
          interface Style extends StyleProps {
            key?: string;
            style?: StyleName;
        \(Node.Gesture.allCases.map { "    \($0.rawValue)?: string;" }.joined(separator: "\n"))
            tooltip?: string;
            hovered?: StyleProps;
            pressed?: StyleProps;
          }
        \(nodes)
          type Node = \(Node.Kind.allCases.map { typeName($0.rawValue) }.joined(separator: " | "));

          type Child = Node | false | null | undefined | Child[];
          type TextChild = string | number | false | null | undefined;
          type ElementProps<N extends Node> = N extends Text
            ? Omit<Text, "type" | "text"> & ({ text: string | number; children?: never } | { text?: never; children: TextChild | TextChild[] })
            : "children" extends keyof N ? Omit<N, "type" | "children"> & { children?: Child } : Omit<N, "type">;
          function h(type: string | ((props: any) => Node), props: object | null, ...children: unknown[]): Node;
          function Fragment(props: { children?: Child }): Node[];
          namespace JSX {
            type Element = Node;
            interface ElementChildrenAttribute { children: {} }
            interface IntrinsicAttributes { key?: string }
            type Elements = { [N in Node as N["type"]]: ElementProps<N> };
            interface IntrinsicElements extends Elements {}
          }
        """
    }

    private static func stateTypes(pluginTopics: [PluginID]) -> String {
        let topics = pluginTopics.map { "    \"\($0)\"?: Json;" }.joined(separator: "\n")
        return """
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
            surface?: string;
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
            attach?: boolean;
          }
        """
    }

    private static func moduleTypes(capabilities: [String]) -> String {
        let modules = PluginKind.allCases.map { "  type \(typeName($0.rawValue)) = \($0 == .service ? "Module" : "Rendered");" }
            .joined(separator: "\n")
        return """
          type ActionPayload = null | number | string;
          interface Storage {
            get(key: string): Json | undefined;
            set(key: string, value: Json | undefined): void;
          }
          interface Host {
            log(message: string): void;
            storage: Storage;
            publish(value: Json): void;
            show(surface?: string): void;
            hide(surface?: string): void;
            toggle(surface?: string): void;
            call(method: string, ...args: string[]): Promise<Json | undefined>;
          }

          interface Module {
            render?(state: State): Node;
            onAction?(action: string, payload: ActionPayload, state: State): void;
            onKey?(key: Key, state: State): boolean | void;
            onScroll?(event: ScrollEvent, state: State): void;
            onHotkey?(id: string, state: State): void;
            onTopic?(topic: string, value: Json, state: State): void;
            methods?: { [name: string]: (...args: string[]) => Json | void | Promise<Json | void> };
            surface?: SurfaceExport;
            surfaces?: { [name: string]: SurfaceExport };
          }
          type SurfaceExport = Surface | null | ((state: State) => Surface | null | undefined);
          interface Rendered extends Module {
            render(state: State): Node;
          }
        \(modules)
        }

        declare const host: Gary.Host;
        declare function setTimeout(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
        declare function setInterval(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
        declare function clearTimeout(id?: number): void;
        declare function clearInterval(id?: number): void;
        \(capabilities.map { $0 + "\n" }.joined())
        """
    }

    public static func manifestSchema(_ capabilities: CapabilityNames) -> JSON {
        let kinds = strings(PluginKind.allCases.map(\.rawValue))
        let id = JSON.object(["$ref": .string("#/$defs/id")])
        let string = type("string")
        let scripts = ScriptLanguage.allCases.map(\.rawValue).joined(separator: "|")
        return .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "title": .string("Gary plugin manifest"),
            "type": .string("object"),
            "required": strings(["schemaVersion", "id", "name", "version", "kinds", "entryPoints"]),
            "$defs": .object(["id": type("string", [
                "maxLength": .number(128), "pattern": .string(#"^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+$"#),
            ])]),
            "properties": .object([
                "$schema": string,
                "schemaVersion": .object(["const": .number(Double(PluginManifest.schemaVersion))]),
                "id": .object(["allOf": .array([id, .object(["not": type("string", ["pattern": .string(#"^gary\."#)])])])]),
                "name": string,
                "version": string,
                "kinds": type("array", ["minItems": .number(1), "uniqueItems": .bool(true), "items": .object(["enum": kinds])]),
                "entryPoints": type("object", [
                    "propertyNames": .object(["enum": kinds]),
                    "additionalProperties": type("string", ["pattern": .string(#"^(?![/~])(?!.*(^|/)\.{0,2}(/|$))[^\u0000]*\.(\#(scripts))$"#)]),
                ]),
                "keepLoaded": type("boolean"),
                "bar": .object(["enum": strings(BarSection.allCases.map(\.rawValue))]),
                "subscribes": type("array", [
                    "items": .object(["anyOf": .array([.object(["enum": strings(capabilities.topics.sorted())]), id])]),
                ]),
                "uses": type("array", ["items": .object(["enum": strings(capabilities.uses.sorted())])]),
                "hotkeys": type("array", ["items": type("object", [
                    "required": strings(["id", "keys"]),
                    "properties": .object([
                        "id": type("string", ["minLength": .number(1)]),
                        "keys": type("string", ["pattern": .string(#"^(([A-Za-z]+\+)+[^+]+|[Ff]([1-9]|1[0-2]))$"#)]),
                    ]),
                ])]),
            ]),
        ])
    }

    private static func type(_ name: String, _ fields: [String: JSON] = [:]) -> JSON {
        .object(fields.merging(["type": .string(name)]) { $1 })
    }

    private static func strings(_ values: [String]) -> JSON {
        .array(values.map(JSON.string))
    }

    static func typeName(_ raw: String) -> String {
        raw.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private static func fields(_ kind: Node.Kind) -> [String] {
        switch kind {
        case .row, .column, .stack: ["children?: Node[];"]
        case .scroll: ["children?: Node[];", "reveal?: string;"]
        case .button: ["children?: Node[];", "hover?: StyleName;"]
        case .text: ["text: string | number;"]
        case .icon: ["symbol: string;"]
        case .image: ["path: string;"]
        case .slider, .progress: ["value: number;"]
        case .input: ["value?: string | number;", "placeholder?: string;", "change?: string;", "submit?: string;"]
        case .spacer: []
        case .shape:
            [
                "viewBox?: [number, number];",
                "paths: { d: string; fill?: Paint; stroke?: Paint; lineWidth?: number; cap?: \(union(ShapePath.Cap.allCases.map(\.rawValue))); "
                    + "join?: \(union(ShapePath.Join.allCases.map(\.rawValue))); dash?: number[]; trim?: [number, number] }[];",
            ]
        case .chart:
            [
                "series: { values: number[]; mark?: \(union(ChartSeries.Mark.allCases.map(\.rawValue))); color?: Paint; smooth?: boolean }[];",
                "min?: number;", "max?: number;", "axes?: boolean;",
            ]
        case .grid: ["columns: number;", "children?: Node[];"]
        case .shader: ["path: string;", "function: string;", "args?: number[];", "animated?: boolean;"]
        }
    }
}
