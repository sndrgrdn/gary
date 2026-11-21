import Foundation

public struct RequestError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum Request: Equatable, Sendable {
    case ping
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

    public static let usage: [(syntax: String, description: String)] = [
        ("ping", "Check that Gary is running."),
        ("summon <plugin>", "Load and show a plugin's panel, overlay or menu."),
        ("hide <plugin>", "Hide a plugin's surface and unload it unless it is keepLoaded."),
        ("toggle <plugin>", "Summon a hidden surface or hide a shown one."),
        ("reloadPlugins [plugin]", "Reload one plugin, or every loaded plugin, from disk."),
        ("rescanPlugins", "Find added and removed plugin directories."),
        ("reloadConfig", "Re-read ~/.config/gary/shell.json."),
        ("applyTheme [json]", "Apply a theme override payload, or re-read the theme files."),
        ("listPlugins", "List every plugin with its state."),
        ("doctor", "Report the version, window levels, private API, permissions, plugin and config problems."),
        ("permissions", "List each macOS permission, whether Gary has it, and the capabilities and enabled plugins that need it. Starts Gary if needed."),
        ("permissions request <name>", "Show the macOS prompt for a permission, or open its System Settings pane where macOS has no prompt."),
        ("call <plugin> <method> [args...]", "Call a method a plugin exports, loading it first if needed."),
    ]

    public static func parse(verb: String, arguments: [String]) throws -> Request {
        func fail(_ message: String) -> RequestError { RequestError(description: message) }
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
        case "summon": try exactly(1); return .summon(try plugin(arguments[0]))
        case "hide": try exactly(1); return .hide(try plugin(arguments[0]))
        case "toggle": try exactly(1); return .toggle(try plugin(arguments[0]))
        case "reloadPlugins": try atMostOne(); return .reloadPlugins(try arguments.first.map(plugin))
        case "rescanPlugins": try exactly(0); return .rescanPlugins
        case "reloadConfig": try exactly(0); return .reloadConfig
        case "applyTheme":
            try atMostOne()
            return .applyTheme(try arguments.first.map { text in
                guard let json = try? JSON.parse(text), json.object != nil else { throw fail("applyTheme takes a JSON object") }
                return json
            })
        case "listPlugins": try exactly(0); return .listPlugins
        case "doctor": try exactly(0); return .doctor
        case "permissions":
            if arguments.isEmpty { return .permissions }
            guard arguments.count == 2, arguments[0] == "request" else { throw fail("permissions takes no arguments, or request and a permission name") }
            guard let permission = Permission(rawValue: arguments[1]) else {
                throw fail("unknown permission \"\(arguments[1])\"; use \(Permission.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .requestPermission(permission)
        case "call":
            guard arguments.count >= 2 else { throw fail("call takes a plugin, a method and optional arguments") }
            return .call(try plugin(arguments[0]), method: arguments[1], arguments: Array(arguments.dropFirst(2)))
        default: throw fail("unknown verb \"\(verb)\"")
        }
    }

    public var verb: String {
        switch self {
        case .ping: return "ping"
        case .summon: return "summon"
        case .hide: return "hide"
        case .toggle: return "toggle"
        case .reloadPlugins: return "reloadPlugins"
        case .rescanPlugins: return "rescanPlugins"
        case .reloadConfig: return "reloadConfig"
        case .applyTheme: return "applyTheme"
        case .listPlugins: return "listPlugins"
        case .doctor: return "doctor"
        case .permissions, .requestPermission: return "permissions"
        case .call: return "call"
        }
    }

    public var arguments: [String] {
        switch self {
        case .ping, .rescanPlugins, .reloadConfig, .listPlugins, .doctor, .permissions: return []
        case .requestPermission(let permission): return ["request", permission.rawValue]
        case .summon(let id), .hide(let id), .toggle(let id): return [id.rawValue]
        case .reloadPlugins(let id): return id.map { [$0.rawValue] } ?? []
        case .applyTheme(let payload): return payload.map { [$0.text] } ?? []
        case .call(let id, let method, let arguments): return [id.rawValue, method] + arguments
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

public enum Response: Equatable, Sendable {
    case ok(String)
    case failure(String)

    public var line: String {
        switch self {
        case .ok(let result): return JSON.object(["ok": .bool(true), "result": .string(result)]).text
        case .failure(let message): return JSON.object(["ok": .bool(false), "error": .string(message)]).text
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
