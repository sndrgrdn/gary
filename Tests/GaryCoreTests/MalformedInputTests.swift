import Foundation
@testable import GaryCore
import Testing

private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources")

private func loadBaseTheme() throws -> JSON {
    try JSON.parse(Data(contentsOf: resources.appending(path: "theme.json")))
}

private func makeCapabilities() throws -> CapabilityNames {
    try CapabilityNames([
        CapabilityDeclaration("exec", installs: true, publishes: false),
        CapabilityDeclaration("battery", installs: false, publishes: true),
        CapabilityDeclaration("clock", installs: false, publishes: true),
    ])
}

private let shellSample = """
{"plugins": ["demo.osd", "demo.counter"], "disabledPlugins": ["gary.today"], "bar": {"left": ["demo.counter"], "right": ["gary.clock"]},
 "settings": {"demo.counter": {"step": 2}}}
"""
private let themeSample = """
{"colors": {"accent": "mix(accent, #ff0000, 0.5)", "dim": ["alpha(foreground, 0.4)", "#888"]}, "bar": {"height": 30},
 "spacing": {"edge": 8, "section": 12}, "motion": {"fade": 0.12}, "styles": {"default": {"font": "body", "color": "foreground"}}}
"""
private let paletteSample = """
mode = "dark"
background = "#101315"
foreground = '#c1c497'
accent = #798186
color1 = "#e06c75"
"""
private let manifestSample = """
{"schemaVersion": 1, "id": "demo.counter", "name": "Counter", "version": "0.1.0", "kinds": ["service", "bar-widget", "menu"],
 "entryPoints": {"service": "service.js", "bar-widget": "widget.js", "menu": "menu.js"}, "subscribes": ["demo.counter", "clock"],
 "uses": ["exec"], "keepLoaded": true, "hotkeys": [{"id": "open", "keys": "cmd+shift+k"}]}
"""
private let nodeSample = """
{"type": "column", "style": "panel", "children": [{"type": "text", "value": "hi", "style": "body"},
 {"type": "button", "action": "go", "children": [{"type": "icon", "value": "star"}]}, {"type": "slider", "value": 0.5, "action": "set"},
 {"type": "input", "value": "x", "placeholder": "type", "change": "c", "submit": "s"}, {"type": "scroll", "children": []}]}
"""
private let surfaceSample = """
{"screen": "all", "anchors": {"top": true, "left": true}, "width": 300, "height": "fit", "margins": {"top": 8}, "layer": "overlay",
 "exclusionMode": "ignore", "clickThrough": true, "focusable": false}
"""

private func nested(_ depth: Int, _ open: String, _ close: String, _ middle: String = "1") -> String {
    String(repeating: open, count: depth) + middle + String(repeating: close, count: depth)
}

private let hostileStrings: [String] = [
    "", " ", "\u{0}", "#", "#ffffffff00", "#zzz", "mix(", "mix(a, b, 2)", "alpha(foreground, -1)", "alpha(foreground, 1e308)",
    "mix(foreground, background, nan)", "mix(foreground, background, inf)", "contrast()", "contrast(contrast(contrast(#fff)))",
    nested(2000, "contrast(", ")", "#fff"), String(repeating: "a", count: 100_000), "cmd+shift+", "cmd+cmd+cmd+k", "🙂", "../../etc/passwd",
]

private let hostileValues: [JSON] = [
    .null, .bool(true), .number(0), .number(-1), .number(1.5), .number(1e308), .number(-1e308), .number(9.3e18), .number(-9.3e18),
    .number(4.9e-324), .array([]), .object([:]), .array([.null, .number(1e308)]), .object(["type": .string("text")]),
] + hostileStrings.map(JSON.string)

private func mutate(_ json: JSON, _ random: inout SeededRandom) -> JSON {
    switch json {
    case var .object(fields) where !fields.isEmpty && random.next(4) != 0:
        let keys = fields.keys.sorted()
        let key = keys[random.next(keys.count)]
        switch random.next(5) {
        case 0: fields[key] = nil
        case 1: fields[key] = hostileValues[random.next(hostileValues.count)]
        case 2: fields[hostileStrings[random.next(hostileStrings.count)]] = hostileValues[random.next(hostileValues.count)]
        default: fields[key] = fields[key].map { mutate($0, &random) }
        }
        return .object(fields)
    case var .array(items) where !items.isEmpty && random.next(4) != 0:
        let index = random.next(items.count)
        switch random.next(4) {
        case 0: items.remove(at: index)
        case 1: items.append(items[index])
        default: items[index] = mutate(items[index], &random)
        }
        return .array(items)
    default:
        return hostileValues[random.next(hostileValues.count)]
    }
}

private let punctuation = Array("{}[]\",:#=\n'\\".utf8)

private func mutatedTexts(_ sample: String, count: Int, seed: UInt64) -> [String] {
    var random = SeededRandom(seed: seed)
    let json = try? JSON.parse(sample)
    var texts = [nested(5000, "[", "]"), nested(5000, "{\"a\":", "}"), "", "\u{0}\u{1}", String(repeating: "{", count: 100_000)]
    for _ in 0..<count {
        if let json, random.next(3) != 0 {
            var value = json
            for _ in 0...random.next(4) {
                value = mutate(value, &random)
            }
            texts.append(value.text)
        } else {
            var bytes = Array(sample.utf8)
            for _ in 0...random.next(8) where !bytes.isEmpty {
                let index = random.next(bytes.count)
                switch random.next(4) {
                case 0: bytes[index] = UInt8(random.next(256))
                case 1: bytes.remove(at: index)
                case 2: bytes.insert(punctuation[random.next(punctuation.count)], at: index)
                default: bytes = Array(bytes[..<index])
                }
            }
            texts.append(String(decoding: bytes, as: UTF8.self))
        }
    }
    return texts
}

struct MalformedInputTests {
    @Test func `malformed shell configs are rejected or resolved without crashing`() throws {
        let capabilities = try makeCapabilities()
        var catalog = PluginCatalog()
        for text in mutatedTexts(manifestSample, count: 50, seed: 7) {
            if let manifest = try? PluginManifest.parse(Data(text.utf8), origin: .user, capabilities: capabilities) {
                catalog.plugins[manifest.id] = PluginBundle(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/\(manifest.id)"), origin: .user)
            }
        }
        for text in mutatedTexts(shellSample, count: 3000, seed: 1) {
            guard let json = try? JSON.parse(text), let config = try? ShellConfig.parse(json) else { continue }
            _ = config.resolve(catalog)
        }
    }

    @Test func `malformed themes are rejected or parsed without crashing`() throws {
        let baseTheme = try loadBaseTheme()
        let palettes = [Palette(nil, system: .dark), Palette(PaletteFile.parse(paletteSample), system: .light)]
        for (index, text) in mutatedTexts(themeSample, count: 3000, seed: 2).enumerated() {
            guard let json = try? JSON.parse(text) else { continue }
            if let theme = try? Theme.parse(baseTheme, palette: palettes[index % 2], override: json) {
                _ = theme.json.text
            }
        }
        for text in mutatedTexts(baseTheme.text, count: 1000, seed: 3) {
            guard let json = try? JSON.parse(text) else { continue }
            _ = (try? Theme.parse(json, palette: palettes[0]))?.json.text
        }
    }

    @Test func `malformed palettes keep the good lines without crashing`() throws {
        let baseTheme = try loadBaseTheme()
        var texts = mutatedTexts(paletteSample, count: 3000, seed: 4)
        texts += hostileStrings.map { "accent = \"\($0)\"" } + hostileStrings
        for text in texts {
            let file = PaletteFile.parse(text)
            for mode in [Palette.Mode.dark, .light] {
                _ = (try? Theme.parse(baseTheme, palette: Palette(file, system: mode)))?.json.text
            }
        }
    }

    @Test func `malformed manifests nodes surfaces and requests are rejected without crashing`() throws {
        let capabilities = try makeCapabilities()
        for text in mutatedTexts(manifestSample, count: 3000, seed: 5) {
            for origin in [PluginOrigin.user, .builtin] {
                _ = try? PluginManifest.parse(Data(text.utf8), origin: origin, capabilities: capabilities)
            }
        }
        for text in mutatedTexts(nodeSample, count: 3000, seed: 6) {
            _ = try? Node.parse(Data(text.utf8))
        }
        for text in mutatedTexts(surfaceSample, count: 3000, seed: 8) {
            guard let json = try? JSON.parse(text) else { continue }
            for kind in PluginKind.allCases {
                _ = try? SurfaceSpec.parse(json, kind: kind)
            }
        }
        for text in mutatedTexts(#"{"verb": "call", "args": ["demo.counter", "add", "1"]}"#, count: 3000, seed: 9) {
            _ = try? Request.decode(line: text)
            _ = try? Response.decode(line: text)
        }
    }
}
