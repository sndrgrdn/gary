import GaryCore
import JavaScriptCore

enum Permission {
    case accessibility, bluetooth, location, notifications
}

struct Capability {
    let name: String
    var permission: Permission?
    var install: ((JSValue, PluginRuntime) -> Void)?

    static let all: [Capability] = [
        .exec,
        .files,
        .network,
    ]

    static func names() throws -> CapabilityNames {
        try CapabilityNames(uses: all.filter { $0.install != nil }.map(\.name))
    }
}
