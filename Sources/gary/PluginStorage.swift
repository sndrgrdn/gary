import Foundation
import GaryCore

nonisolated enum PluginStorage {
    private static let lock = NSLock()

    static func get(_ id: PluginID, _ key: String) -> JSON? {
        lock.withLock { values(id)[key] }
    }

    static func set(_ id: PluginID, _ key: String, _ value: JSON?) throws {
        try lock.withLock {
            var values = values(id)
            values[key] = value
            try FileManager.default.createDirectory(at: Paths.storage, withIntermediateDirectories: true)
            try JSON.object(values).encoded().write(to: file(id), options: .atomic)
        }
    }

    private static func file(_ id: PluginID) -> URL {
        Paths.storage.appending(path: "\(id).json")
    }

    private static func values(_ id: PluginID) -> [String: JSON] {
        (try? JSON.parse(Data(contentsOf: file(id))))?.object ?? [:]
    }
}
