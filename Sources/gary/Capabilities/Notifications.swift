import AppKit
import GaryCore
import SQLite3

extension Capability {
    static let notifications = Capability(
        name: "notifications",
        summary: "Notifications that Notification Center delivered. Open the app that sent one.",
        types: """
        declare namespace Gary {
          interface State { notifications?: Notifications }
          interface Notifications { available: boolean; reason?: string; items: DeliveredNotification[] }
          interface DeliveredNotification {
            id: number;
            app: string;
            appName: string | null;
            title: string | null;
            subtitle: string | null;
            body: string | null;
            date: number;
          }
          interface Host { notifications: { open(id: number): null } }
        }
        """,
        example: """
        module.exports = {
          render(state) {
            const notifications = state.notifications;
            if (!notifications?.available) return { type: "text", text: notifications?.reason ?? "…", style: "dim" };
            return {
              type: "column",
              children: notifications.items.slice(0, 5).map((item) => (
                { type: "text", key: String(item.id), action: String(item.id), text: `${item.appName ?? item.app}: ${item.title ?? item.body ?? ""}` }
              )),
            };
          },
          onAction(id) {
            host.notifications.open(Number(id));
          },
        } satisfies Gary.Panel;
        """,
        permissions: [.fullDiskAccess],
        install: { host, plugin in
            plugin.installAPI(host, "notifications", NotificationsRequest.methods) { call in
                switch try NotificationsRequest.parse(call) {
                case let .open(id):
                    let records = try NotificationStore.read("WHERE r.rec_id = \(id)").mapError { HostFailure($0.reason) }.get()
                    guard let record = records.first else { throw HostFailure("no delivered notification \(id)") }
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.app)
                    else { throw HostFailure("\(record.app) is not installed") }
                    DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                    return .now(.null)
                }
            }
        },
        topic: { NotificationsTopic($0) },
    )
}

private enum NotificationStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Group Containers/group.com.apple.usernoted/db2")

    struct Failure: Error {
        let reason: String
    }

    static func read(_ filter: String = "") -> Result<[DeliveredNotification], Failure> {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        let opened = sqlite3_open_v2(directory.appending(path: "db").path, &database, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, sqlite3_exec(database, "PRAGMA query_only = 1", nil, nil, nil) == SQLITE_OK else {
            let denied = opened == SQLITE_AUTH || opened == SQLITE_CANTOPEN || opened == SQLITE_PERM
            return .failure(Failure(reason: denied ? missingGrant(.fullDiskAccess, "notifications") :
                    "cannot open the notification database (\(opened))"))
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON a.app_id = r.app_id \(filter) ORDER BY r.delivered_date DESC LIMIT 50"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return .failure(Failure(reason: "the notification database has an unknown layout: \(String(cString: sqlite3_errmsg(database)))"))
        }
        var records: [DeliveredNotification] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let app = sqlite3_column_text(statement, 1), let blob = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            if let record = DeliveredNotification(id: Int(sqlite3_column_int64(statement, 0)), appColumn: String(cString: app), record: data) {
                records.append(record)
            }
        }
        return .success(records)
    }
}

private final class NotificationsTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private let queue = DispatchQueue(label: "gary.notifications")
    private var names: [String: String] = [:]
    private var observation: Observation?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        let watch = PathWatch(["", "db", "db-wal"].map { NotificationStore.directory.appending(path: $0).path }, queue: queue) { [weak self] in
            self?.refresh(Trace("notifications"))
        }
        observation = Observation { watch.stop() }
        refresh(Trace("notifications-start"))
    }

    private func refresh(_ trace: Trace) {
        queue.async { [weak self] in
            guard let self else { return }
            switch NotificationStore.read() {
            case let .failure(failure):
                publish(.object(["available": .bool(false), "reason": .string(failure.reason), "items": .array([])]), trace)
            case let .success(records):
                publish(.object(["available": .bool(true), "items": .array(records.map(json))]), trace)
            }
        }
    }

    private func json(_ record: DeliveredNotification) -> JSON {
        func text(_ value: String?) -> JSON {
            value.map(JSON.string) ?? .null
        }
        return .object([
            "id": .number(Double(record.id)), "app": .string(record.app), "appName": text(name(record.app)),
            "title": text(record.title), "subtitle": text(record.subtitle), "body": text(record.body), "date": .number(record.date.rounded()),
        ])
    }

    private func name(_ app: String) -> String? {
        if let name = names[app] {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[app] = name
        return name
    }
}
