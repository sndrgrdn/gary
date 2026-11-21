import Foundation
import GaryCore
import JavaScriptCore

enum Permission {
    case accessibility, bluetooth, location, notifications
}

struct Capability {
    let name: String
    var permission: Permission?
    var install: ((JSValue, PluginRuntime) -> Void)?
    var topic: TopicSource?

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

    static var topics: [Topic: TopicSource] {
        Dictionary(uniqueKeysWithValues: all.compactMap { capability in capability.topic.map { (Topic.capability(capability.name), $0) } })
    }
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
