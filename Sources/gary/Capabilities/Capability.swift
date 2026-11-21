import GaryCore
import JavaScriptCore

enum Permission: String, CaseIterable {
    case accessibility, bluetooth, fullDiskAccess, location, notifications
}

struct Capability {
    let name: String
    let types: String
    var permission: Permission?
    var install: ((JSValue, PluginRuntime) -> Void)?
    var topic: ((@escaping (JSON, Trace) -> Void) -> AnyObject)?

    static let all: [Capability] = [
        .battery,
        .clock,
        .exec,
        .files,
        .network,
    ]

    static func names() throws -> CapabilityNames {
        try CapabilityNames(all.map { ($0.name, $0.install != nil, $0.topic != nil) })
    }
}
