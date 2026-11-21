import Foundation

public struct RequestError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum Request: Equatable, Sendable {
    case ping
    case quit
    case summon(PluginID)
    case hide(PluginID)
    case toggle(PluginID)
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

    public static let usage: [(syntax: String, description: String, example: String?)] = [
        ("ping", "Check that Gary is running.", nil),
        ("quit", "Stop Gary and its crash supervisor, restoring the menu bar and Dock settings that plugins changed.", nil),
        ("summon <plugin>", "Load and show a plugin's panel, overlay or menu.", "gary summon you.launcher"),
        ("hide <plugin>", "Hide a plugin's surface and unload it unless it is keepLoaded.", nil),
        ("toggle <plugin>", "Summon a hidden surface or hide a shown one.", nil),
        ("reloadPlugins [plugin]", "Reload one plugin, or every loaded plugin, from disk.", nil),
        ("rescanPlugins", "Find added and removed plugin directories.", nil),
        ("reloadConfig", "Re-read ~/.config/gary/shell.json.", nil),
        (
            "applyTheme [json]",
            "Apply a theme override payload, or re-read the theme files.",
            ##"gary applyTheme '{"colors": {"accent": "#ff8800"}}'"##,
        ),
        ("listPlugins", "List every plugin with its state.", nil),
        ("doctor", "Report the version, window levels, private API, permissions, plugin and config problems.", nil),
        (
            "onboarding",
            "Show the permissions window, which lists what the enabled plugins need, with a Grant button for each. Starts Gary if needed.",
            nil,
        ),
        (
            "permissions",
            "List each macOS permission, whether Gary has it, and the capabilities and enabled plugins that need it. Starts Gary if needed.",
            nil,
        ),
        (
            "permissions request <name>",
            "Show the macOS prompt for a permission, or open its System Settings pane where macOS has no prompt.",
            "gary permissions request screen-recording",
        ),
        (
            "call <plugin> <method> [args...]",
            "Call a method a plugin exports, loading it first if needed. Arguments arrive as strings. Gary waits up to 60 seconds for a method that returns a promise. A result that is not a string prints as JSON, and a thrown error or rejected promise prints its message and exits with status 1.",
            "gary call you.weather forecast 3",
        ),
        (
            "action <plugin> <kind> <action> [payload]",
            "Send onAction to a running kind of a plugin, as a click, slider or input would, with an optional number or text payload.",
            "gary action you.music panel volume 0.5",
        ),
    ]

    public static let callTimeout: TimeInterval = 60

    public var timeout: TimeInterval {
        verb == "call" ? Self.callTimeout + 1 : 5
    }

    public static func parse(verb: String, arguments: [String]) throws -> Request {
        func fail(_ message: String) -> RequestError {
            RequestError(description: message)
        }
        func plugin(_ raw: String) throws -> PluginID {
            guard let id = PluginID(raw) else { throw fail("invalid plugin id \"\(raw)\"") }
            return id
        }
        func exactly(_ count: Int) throws {
            guard arguments.count == count else { throw fail("\(verb) takes \(count) argument\(count == 1 ? "" : "s")") }
        }
        func atMostOne() throws {
            guard arguments.count <= 1 else { throw fail("\(verb) takes at most 1 argument") }
        }
        switch verb {
        case "ping": try exactly(0); return .ping
        case "quit": try exactly(0); return .quit
        case "summon": try exactly(1); return try .summon(plugin(arguments[0]))
        case "hide": try exactly(1); return try .hide(plugin(arguments[0]))
        case "toggle": try exactly(1); return try .toggle(plugin(arguments[0]))
        case "reloadPlugins": try atMostOne(); return try .reloadPlugins(arguments.first.map(plugin))
        case "rescanPlugins": try exactly(0); return .rescanPlugins
        case "reloadConfig": try exactly(0); return .reloadConfig
        case "applyTheme":
            try atMostOne()
            return try .applyTheme(arguments.first.map { text in
                guard let json = try? JSON.parse(text), json.object != nil else { throw fail("applyTheme takes a JSON object") }
                return json
            })
        case "listPlugins": try exactly(0); return .listPlugins
        case "doctor": try exactly(0); return .doctor
        case "onboarding": try exactly(0); return .summon(.onboarding)
        case "permissions":
            if arguments.isEmpty {
                return .permissions
            }
            guard arguments.count == 2,
                  arguments[0] == "request" else { throw fail("permissions takes no arguments, or request and a permission name") }
            guard let permission = Permission(rawValue: arguments[1]) else {
                throw fail("unknown permission \"\(arguments[1])\"; use \(Permission.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .requestPermission(permission)
        case "call":
            guard arguments.count >= 2 else { throw fail("call takes a plugin, a method and optional arguments") }
            return try .call(plugin(arguments[0]), method: arguments[1], arguments: Array(arguments.dropFirst(2)))
        case "action":
            guard (3...4).contains(arguments.count) else { throw fail("action takes a plugin, a kind, an action and an optional payload") }
            guard let kind = PluginKind(rawValue: arguments[1]) else {
                throw fail("unknown kind \"\(arguments[1])\"; use \(PluginKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return try .action(plugin(arguments[0]), kind: kind, action: arguments[2], payload: arguments.count == 4 ? arguments[3] : nil)
        default: throw fail("unknown verb \"\(verb)\"")
        }
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
        case let .summon(id), let .hide(id), let .toggle(id): [id.rawValue]
        case let .reloadPlugins(id): id.map { [$0.rawValue] } ?? []
        case let .applyTheme(payload): payload.map { [$0.text] } ?? []
        case let .call(id, method, arguments): [id.rawValue, method] + arguments
        case let .action(id, kind, action, payload): [id.rawValue, kind.rawValue, action] + (payload.map { [$0] } ?? [])
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
