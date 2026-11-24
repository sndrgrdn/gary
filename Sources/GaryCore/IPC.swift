import Foundation

public struct RequestError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum Request: Equatable, Sendable {
    case ping
    case quit
    case summon(SurfaceAddress)
    case hide(SurfaceAddress)
    case toggle(SurfaceAddress)
    case reloadPlugins(PluginID?)
    case rescanPlugins
    case reloadConfig
    case applyTheme(JSON?)
    case listPlugins
    case doctor
    case stats(PluginID?)
    case permissions
    case requestPermission(Permission)
    case call(PluginID, method: String, arguments: [String])
    case action(PluginID, kind: PluginKind, action: String, payload: String?)
    case key(PluginID, kind: PluginKind?, keys: [String])
    case scroll(PluginID, kind: PluginKind, over: String?, by: ScrollDistance)
    case hover(PluginID, kind: PluginKind, action: String, entering: Bool)
    case click(PluginID, kind: PluginKind, at: CGPoint)
    case tree(PluginID, kind: PluginKind)
    case capture(PluginID, kind: PluginKind, to: String)
    case frames(record: TimeInterval?)

    public static let callTimeout: TimeInterval = 60

    public var timeout: TimeInterval {
        if case let .frames(seconds?) = self {
            return seconds + 5
        }
        return verb == "call" ? Self.callTimeout + 1 : 5
    }

    private static let bareVerbs: [String: Request] = [
        "ping": .ping, "quit": .quit, "rescanPlugins": .rescanPlugins, "reloadConfig": .reloadConfig,
        "listPlugins": .listPlugins, "doctor": .doctor, "onboarding": .summon(SurfaceAddress(.onboarding)),
    ]

    private static let surfaceVerbs: [String: @Sendable (SurfaceAddress) -> Request] = [
        "summon": Request.summon, "hide": Request.hide, "toggle": Request.toggle,
    ]

    public static func parse(verb: String, arguments: [String]) throws -> Request {
        if let request = bareVerbs[verb] {
            try expect(arguments, count: 0, for: verb)
            return request
        }
        if let request = surfaceVerbs[verb] {
            try expect(arguments, count: 1, for: verb)
            return try request(surface(arguments[0]))
        }
        switch verb {
        case "reloadPlugins":
            try expectAtMostOne(arguments, for: verb)
            return try .reloadPlugins(arguments.first.map(plugin))
        case "stats":
            try expectAtMostOne(arguments, for: verb)
            return try .stats(arguments.first.map(plugin))
        case "applyTheme":
            try expectAtMostOne(arguments, for: verb)
            return try .applyTheme(arguments.first.map(themeOverride))
        case "permissions": return try permissions(arguments)
        case "call": return try call(arguments)
        case "action": return try action(arguments)
        case "key": return try key(arguments)
        case "scroll": return try scroll(arguments)
        case "hover": return try hover(arguments)
        case "click": return try click(arguments)
        case "frames": return try frames(arguments)
        case "capture":
            try expect(arguments, count: 2, for: verb)
            let (id, kind) = try slotWithKind(arguments[0], for: verb)
            return .capture(id, kind: kind, to: URL(fileURLWithPath: arguments[1]).standardizedFileURL.path)
        case "tree":
            try expect(arguments, count: 1, for: verb)
            let (id, kind) = try slotWithKind(arguments[0], for: verb)
            return .tree(id, kind: kind)
        default: throw RequestError(description: "unknown verb \"\(verb)\"")
        }
    }

    private static func expect(_ arguments: [String], count: Int, for verb: String) throws {
        guard arguments.count == count else { throw RequestError(description: "\(verb) takes \(count) argument\(count == 1 ? "" : "s")") }
    }

    private static func expectAtMostOne(_ arguments: [String], for verb: String) throws {
        guard arguments.count <= 1 else { throw RequestError(description: "\(verb) takes at most 1 argument") }
    }

    private static func plugin(_ raw: String) throws -> PluginID {
        guard let id = PluginID(raw) else { throw RequestError(description: "invalid plugin id \"\(raw)\"") }
        return id
    }

    private static func surface(_ raw: String) throws -> SurfaceAddress {
        guard let address = SurfaceAddress(raw) else {
            _ = try plugin(raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw)
            throw RequestError(description: "invalid surface name in \"\(raw)\"; use lowercase letters, digits and hyphens after the colon")
        }
        return address
    }

    private static func themeOverride(_ text: String) throws -> JSON {
        guard let json = try? JSON.parse(text), json.object != nil else { throw RequestError(description: "applyTheme takes a JSON object") }
        return json
    }

    private static func permissions(_ arguments: [String]) throws -> Request {
        if arguments.isEmpty {
            return .permissions
        }
        guard arguments.count == 2, arguments[0] == "request" else {
            throw RequestError(description: "permissions takes no arguments, or request and a permission name")
        }
        guard let permission = Permission(rawValue: arguments[1]) else {
            let names = Permission.allCases.map(\.rawValue).joined(separator: ", ")
            throw RequestError(description: "unknown permission \"\(arguments[1])\"; use \(names)")
        }
        return .requestPermission(permission)
    }

    private static func call(_ arguments: [String]) throws -> Request {
        guard arguments.count >= 2 else { throw RequestError(description: "call takes a plugin, a method and optional arguments") }
        return try .call(plugin(arguments[0]), method: arguments[1], arguments: Array(arguments.dropFirst(2)))
    }

    private static func slot(_ raw: String) throws -> (PluginID, PluginKind?) {
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let id = try plugin(parts[0])
        guard parts.count == 2 else { return (id, nil) }
        guard let kind = PluginKind(rawValue: parts[1]) else {
            let kinds = PluginKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw RequestError(description: "unknown kind \"\(parts[1])\"; use \(kinds)")
        }
        return (id, kind)
    }

    private static func slotWithKind(_ raw: String, for verb: String) throws -> (PluginID, PluginKind) {
        let (id, kind) = try slot(raw)
        guard let kind else { throw RequestError(description: "\(verb) takes <plugin>/<kind>, such as \(id)/panel") }
        return (id, kind)
    }

    private static func action(_ arguments: [String]) throws -> Request {
        guard (2...3).contains(arguments.count) else {
            throw RequestError(description: "action takes <plugin>/<kind>, an action and an optional payload")
        }
        let (id, kind) = try slotWithKind(arguments[0], for: "action")
        return .action(id, kind: kind, action: arguments[1], payload: arguments.count == 3 ? arguments[2] : nil)
    }

    private static func key(_ arguments: [String]) throws -> Request {
        guard arguments.count >= 2 else { throw RequestError(description: "key takes <plugin>[/<kind>] and one or more keys") }
        let (id, kind) = try slot(arguments[0])
        return .key(id, kind: kind, keys: Array(arguments.dropFirst()))
    }

    private static func scroll(_ arguments: [String]) throws -> Request {
        let precise = arguments.last == "--precise"
        let positional = precise ? arguments.dropLast() : arguments[...]
        guard (2...3).contains(positional.count), let y = positional.last.flatMap(Double.init), y.isFinite else {
            throw RequestError(
                description: "scroll takes <plugin>/<kind>, an optional action, a number of lines or points, and an optional --precise",
            )
        }
        let (id, kind) = try slotWithKind(arguments[0], for: "scroll")
        return .scroll(id, kind: kind, over: positional.count == 3 ? positional[1] : nil, by: precise ? .points(y) : .lines(y))
    }

    private static func hover(_ arguments: [String]) throws -> Request {
        guard (2...3).contains(arguments.count), arguments.count == 2 || arguments[2] == "off" else {
            throw RequestError(description: "hover takes <plugin>/<kind>, a hoverAction and an optional off")
        }
        let (id, kind) = try slotWithKind(arguments[0], for: "hover")
        return .hover(id, kind: kind, action: arguments[1], entering: arguments.count == 2)
    }

    private static func click(_ arguments: [String]) throws -> Request {
        let numbers = arguments.dropFirst().compactMap(Double.init).filter(\.isFinite)
        guard arguments.count == 3, numbers.count == 2 else { throw RequestError(description: "click takes <plugin>/<kind>, an x and a y in points") }
        let (id, kind) = try slotWithKind(arguments[0], for: "click")
        return .click(id, kind: kind, at: CGPoint(x: numbers[0], y: numbers[1]))
    }

    private static func frames(_ arguments: [String]) throws -> Request {
        guard !arguments.isEmpty else { return .frames(record: nil) }
        guard arguments.count == 2, arguments[0] == "--record", let seconds = Double(arguments[1]), seconds > 0, seconds <= Frame.kept else {
            throw RequestError(description: "frames takes no arguments, or --record and a number of seconds up to \(Int(Frame.kept))")
        }
        return .frames(record: seconds)
    }

    public var verb: String {
        switch self {
        case .ping: "ping"
        case .quit: "quit"
        case .summon: "summon"
        case .hide: "hide"
        case .toggle: "toggle"
        case .reloadPlugins: "reloadPlugins"
        case .rescanPlugins: "rescanPlugins"
        case .reloadConfig: "reloadConfig"
        case .applyTheme: "applyTheme"
        case .listPlugins: "listPlugins"
        case .doctor: "doctor"
        case .stats: "stats"
        case .permissions, .requestPermission: "permissions"
        case .call: "call"
        case .action: "action"
        case .key: "key"
        case .scroll: "scroll"
        case .hover: "hover"
        case .click: "click"
        case .tree: "tree"
        case .capture: "capture"
        case .frames: "frames"
        }
    }

    public var arguments: [String] {
        switch self {
        case .ping, .quit, .rescanPlugins, .reloadConfig, .listPlugins, .doctor, .permissions: []
        case let .requestPermission(permission): ["request", permission.rawValue]
        case let .summon(address), let .hide(address), let .toggle(address): [address.description]
        case let .reloadPlugins(id), let .stats(id): id.map { [$0.rawValue] } ?? []
        case let .applyTheme(payload): payload.map { [$0.text] } ?? []
        case let .call(id, method, arguments): [id.rawValue, method] + arguments
        case let .action(id, kind, action, payload): ["\(id)/\(kind.rawValue)", action] + (payload.map { [$0] } ?? [])
        case let .key(id, kind, keys): [kind.map { "\(id)/\($0.rawValue)" } ?? id.rawValue] + keys
        case let .scroll(id, kind, over, .lines(y)): ["\(id)/\(kind.rawValue)"] + (over.map { [$0] } ?? []) + [String(y)]
        case let .scroll(id, kind, over, .points(y)): ["\(id)/\(kind.rawValue)"] + (over.map { [$0] } ?? []) + [String(y), "--precise"]
        case let .hover(id, kind, action, entering): ["\(id)/\(kind.rawValue)", action] + (entering ? [] : ["off"])
        case let .tree(id, kind): ["\(id)/\(kind.rawValue)"]
        case let .capture(id, kind, path): ["\(id)/\(kind.rawValue)", path]
        case let .click(id, kind, point): ["\(id)/\(kind.rawValue)", String(Double(point.x)), String(Double(point.y))]
        case let .frames(seconds): seconds.map { ["--record", String($0)] } ?? []
        }
    }

    public var line: String {
        JSON.object(["verb": .string(verb), "args": .array(arguments.map(JSON.string))]).text
    }

    public static func decode(line: String) throws -> Request {
        guard let json = try? JSON.parse(line), let verb = json["verb"]?.string else {
            throw RequestError(description: "a request is a JSON object with a string verb")
        }
        let raw = json["args"]?.array ?? []
        let arguments = raw.compactMap(\.string)
        guard arguments.count == raw.count else { throw RequestError(description: "args must be strings") }
        return try parse(verb: verb, arguments: arguments)
    }
}

public extension Request {
    static let usage: [CommandUsage] = [
        CommandUsage("ping", "Check that Gary is running.", nil),
        CommandUsage("quit", "Stop Gary and its crash supervisor, restoring the menu bar and Dock settings that plugins changed.", nil),
        CommandUsage(
            "summon <plugin>[:<surface>]",
            "Load and show a plugin's panel, overlay or menu. Name a surface to show one other than main.",
            "gary summon you.music:osd",
        ),
        CommandUsage(
            "hide <plugin>[:<surface>]",
            "Hide a plugin's surface, main unless named, and unload the plugin when no surface of its kind stays shown, unless it is keepLoaded.",
            nil,
        ),
        CommandUsage("toggle <plugin>[:<surface>]", "Summon a hidden surface or hide a shown one.", nil),
        CommandUsage("reloadPlugins [plugin]", "Reload one plugin, or every loaded plugin, from disk.", nil),
        CommandUsage("rescanPlugins", "Find added and removed plugin directories.", nil),
        CommandUsage("reloadConfig", "Re-read ~/.config/gary/shell.json.", nil),
        CommandUsage(
            "applyTheme [json]",
            "Apply a theme override payload, or re-read the theme files.",
            ##"gary applyTheme '{"colors": {"accent": "#ff8800"}}'"##,
        ),
        CommandUsage("listPlugins", "List every plugin with its state.", nil),
        CommandUsage("doctor", "Report the version, private API, permissions, plugin and config problems, and other bars that are running.", nil),
        CommandUsage(
            "stats [plugin] [--watch]",
            """
            Print one JSON line per loaded plugin kind with what it costs since it loaded: engine CPU time, entries by cause, renders, \
            timer fires in the last minute, live timers, pending host calls, the longest entry, entries stopped at the time limit, \
            and the nodes, images, views and layers that Gary holds for it. With --watch, print them again every second.
            """,
            "gary stats you.weather --watch",
        ),
        CommandUsage(
            "onboarding",
            "Show the permissions window, which lists what the enabled plugins need, with a Grant button for each. Starts Gary if needed.",
            nil,
        ),
        CommandUsage(
            "permissions",
            "List each macOS permission, whether Gary has it, and the capabilities and enabled plugins that need it. Starts Gary if needed.",
            nil,
        ),
        CommandUsage(
            "permissions request <name>",
            "Show the macOS prompt for a permission, or open its System Settings pane where macOS has no prompt.",
            "gary permissions request screen-recording",
        ),
        CommandUsage(
            "call <plugin> <method> [args...]",
            """
            Call a method a plugin exports, loading it first if needed. Arguments arrive as strings. \
            Gary waits up to 60 seconds for a method that returns a promise. \
            A result that is not a string prints as JSON, and a thrown error or rejected promise prints its message and exits with status 1.
            """,
            "gary call you.weather forecast 3",
        ),
        CommandUsage(
            "action <plugin>/<kind> <action> [payload]",
            """
            Click the shown node of a running kind whose action, rightAction or middleAction has this name, so onAction gets the node's frame \
            as from a real click. Send any other action, such as an input's change, without a frame. The payload is an optional number or text.
            """,
            "gary action you.music/panel volume 0.5",
        ),
        CommandUsage(
            "key <plugin>[/<kind>] <key>...",
            """
            Press keys in order, each named as onKey names it, as the user would. A key that the plugin holds as a hotkey, from its manifest \
            or host.hotkeys, presses that hotkey. \
            Any other key goes to the plugin's focused surface, where an input takes typed characters and onKey gets the rest.
            """,
            "gary key you.launcher s a f enter",
        ),
        CommandUsage(
            "scroll <plugin>/<kind> [action] <dy> [--precise]",
            """
            Scroll by dy over the shown node with this action, or over the surface when no action is named, as the user would, so onScroll gets \
            event.y = dy. A mouse wheel moves in lines; --precise makes a trackpad gesture in points, sent as a began and an ended event.
            """,
            "gary scroll you.music/bar-widget volume 3",
        ),
        CommandUsage(
            "hover <plugin>/<kind> <hoverAction> [off]",
            """
            Move the pointer onto the shown node with this hoverAction, as the user would, so onAction gets the action with true, \
            or with off move it away, so onAction gets false.
            """,
            "gary hover you.launcher/menu row:safari",
        ),
        CommandUsage(
            "click <plugin>/<kind> <x> <y>",
            """
            Click with the left mouse button at a point of the shown surface, in points from its top left corner, as the user would, \
            whether a node with an action, a node without one, or empty space is there.
            """,
            "gary click you.launcher/menu 10 10",
        ),
        CommandUsage(
            "tree <plugin>/<kind>",
            """
            Print the shown nodes of a running kind as an outline: each node's type, key and text, then its frame in points from the top left \
            of its surface, and its color, background, opacity, border and font as drawn now.
            """,
            "gary tree you.launcher/menu",
        ),
        CommandUsage(
            "capture <plugin>/<kind> <file.png>",
            """
            Draw a running kind's shown surface into a PNG at the display's scale, without Screen Recording and without other windows. \
            Blur and materials are left out, since macOS composites them later.
            """,
            "gary capture you.launcher/menu /tmp/launcher.png",
        ),
        CommandUsage(
            "frames [--record <seconds>]",
            """
            Report frame pacing per display: frames, hitch time in ms per second against the display's refresh rate, frame time p50, p99 \
            and max, and for each hitch the main-thread work inside it, such as a plugin's tree, layout, image decode or the Core Animation \
            commit. Gary records frames only while a surface changes or animates. Without --record it summarizes the last 60 seconds; \
            with --record it waits that many seconds and reports only them.
            """,
            "gary frames --record 10",
        ),
    ]
}

public enum ScrollDistance: Equatable, Sendable {
    case lines(Double)
    case points(Double)
}

public extension PluginID {
    static let onboarding = PluginID(builtin: "onboarding")
}
