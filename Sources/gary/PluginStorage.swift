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
        let file = file(id)
        let problem: String
        do {
            if let values = try JSON.parse(Data(contentsOf: file)).object {
                return values
            }
            problem = "not a JSON object"
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            problem = "\(error)"
        }
        let aside = Paths.storage.appending(path: "\(id).corrupt-\(Int(now())).json")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            log("plugin \(id): storage \(file.path) is unreadable (\(problem)), moved it to \(aside.lastPathComponent) and started empty")
        } catch {
            log("plugin \(id): storage \(file.path) is unreadable (\(problem)) and could not be moved aside: \(error)")
        }
        return [:]
    }
}
