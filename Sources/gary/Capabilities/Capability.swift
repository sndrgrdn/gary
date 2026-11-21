import Foundation
import GaryCore
import JavaScriptCore

enum Permission {
    case accessibility, bluetooth, fullDiskAccess, location, notifications
}

struct Capability {
    let name: String
    var permission: Permission?
    var install: ((JSValue, PluginRuntime) -> Void)?
    var topic: TopicSource?

    static let all: [Capability] = [
        .audio,
        .battery,
        .brightness,
        .clock,
        .exec,
        .files,
        .mediakeys,
        .network,
        .notifications,
        .nowplaying,
        .wifi,
    ]

    static func names() throws -> CapabilityNames {
        try CapabilityNames(all.map { ($0.name, $0.install != nil, $0.topic != nil) })
    }

    static var topics: [Topic: TopicSource] {
        Dictionary(uniqueKeysWithValues: all.compactMap { capability in capability.topic.map { (Topic.capability(capability.name), $0) } })
    }
}

func privateSymbol<T>(_ library: String, _ name: String, as type: T.Type) -> T? {
    guard let handle = dlopen(library, RTLD_LAZY), let symbol = dlsym(handle, name) else {
        log("private symbol \(name) is missing from \(library)")
        return nil
    }
    return unsafeBitCast(symbol, to: type)
}

final class Observation {
    private let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    convenience init(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
        self.init { center.removeObserver(token) }
    }

    deinit { cancel() }
}

extension JSValue {
    static func fail(_ message: String) {
        let context = JSContext.current()!
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    static func namespace(_ functions: [String: Any], in host: JSValue, as name: String) {
        let object = JSValue(newObjectIn: host.context)!
        for (key, function) in functions { object.setObject(function, forKeyedSubscript: key as NSString) }
        host.setObject(object, forKeyedSubscript: name as NSString)
    }

    var optionalString: String? { isUndefined || isNull ? nil : toString() }
}
