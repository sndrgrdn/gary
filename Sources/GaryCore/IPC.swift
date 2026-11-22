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
    case permissions
    case requestPermission(Permission)
    case call(PluginID, method: String, arguments: [String])
    case action(PluginID, kind: PluginKind, action: String, payload: String?)

    public static let usage: [CommandUsage] = [
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
        CommandUsage("doctor", "Report the version, private API, permissions, plugin and config problems.", nil),
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
    ]

    public static let callTimeout: TimeInterval = 60

    public var timeout: TimeInterval {
        verb == "call" ? Self.callTimeout + 1 : 5
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
        case "applyTheme":
            try expectAtMostOne(arguments, for: verb)
            return try .applyTheme(arguments.first.map(themeOverride))
        case "permissions": return try permissions(arguments)
        case "call": return try call(arguments)
        case "action": return try action(arguments)
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
        case .permissions, .requestPermission: "permissions"
        case .call: "call"
        case .action: "action"
        }
    }

    public var arguments: [String] {
        switch self {
        case .ping, .quit, .rescanPlugins, .reloadConfig, .listPlugins, .doctor, .permissions: []
        case let .requestPermission(permission): ["request", permission.rawValue]
        case let .summon(address), let .hide(address), let .toggle(address): [address.description]
        case let .reloadPlugins(id): id.map { [$0.rawValue] } ?? []
        case let .applyTheme(payload): payload.map { [$0.text] } ?? []
        case let .call(id, method, arguments): [id.rawValue, method] + arguments
        case let .action(id, kind, action, payload): ["\(id)/\(kind.rawValue)", action] + (payload.map { [$0] } ?? [])
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

public extension PluginID {
    static let onboarding = PluginID(builtin: "onboarding")
}

public enum Response: Equatable, Sendable {
    case ok(String)
    case failure(String)

    public var line: String {
        switch self {
        case let .ok(result): JSON.object(["ok": .bool(true), "result": .string(result)]).text
        case let .failure(message): JSON.object(["ok": .bool(false), "error": .string(message)]).text
        }
    }

    public static func decode(line: String) throws -> Response {
        let json = try? JSON.parse(line)
        switch (json?["ok"]?.bool, json?["result"]?.string, json?["error"]?.string) {
        case (true?, let result?, _): return .ok(result)
        case (false?, _, let message?): return .failure(message)
        default: throw RequestError(description: "malformed response \(line.prefix(200))")
        }
    }
}
