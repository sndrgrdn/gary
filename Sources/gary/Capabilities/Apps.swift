import AppKit
import GaryCore

extension Capability {
    static let apps = Capability(
        name: "apps",
        summary: """
        The frontmost app, the running apps, and the apps installed in the Applications folders. \
        Launch, activate, and quit an app by bundle id or by .app path. `activate` leaves the frontmost app alone and otherwise \
        opens the app the way the Dock does, which brings a running app to the front, even from a hotkey while Gary is in the background.
        """,
        types: """
        declare namespace Gary {
          type Apps = { frontmost: App | null; running: App[] }
          type App = { app: string | null; name: string; pid: number; path: string | null; active: boolean; hidden: boolean }
          type InstalledApp = { name: string; path: string; app: string | null }
          interface Host { apps: AppsApi }
          interface AppsApi {
            installed(): Promise<InstalledApp[]>;
            launch(app: string): Promise<App>;
            activate(app: string): Promise<App>;
            quit(app: string): Promise<{ asked: number }>;
          }
        }
        """,
        example: """
        let installed: Gary.InstalledApp[] = [];
        host.apps.installed().then((apps) => {
          installed = apps;
        });

        export default {
          render() {
            return {
              type: "column",
              children: installed.slice(0, 8).map((app) => ({
                type: "row",
                key: app.path,
                action: app.path,
                children: [{ type: "image", key: "icon", path: app.path, width: 20, height: 20 }, { type: "text", key: "name", text: app.name }],
              })),
            };
          },
          onAction(path) {
            host.apps.activate(path);
          },
        } satisfies Gary.Menu;
        """,
        install: { host, plugin in
            plugin.installAPI(host, "apps", AppsRequest.methods) { call in
                let request = try AppsRequest.parse(call, home: home)
                return .later(.global(qos: .userInitiated)) { try perform(request) }
            }
        },
        topic: CapabilityTopic(type: "Apps") { AppsTopic($0) },
    )
}

private func json(_ app: NSRunningApplication) -> JSON {
    .object([
        "app": app.bundleIdentifier.map(JSON.string) ?? .null,
        "name": .string(app.localizedName ?? ""),
        "pid": .number(Double(app.processIdentifier)),
        "path": app.bundleURL.map { .string($0.path) } ?? .null,
        "active": .bool(app.isActive),
        "hidden": .bool(app.isHidden),
    ])
}

private func perform(_ request: AppsRequest) throws -> JSON {
    switch request {
    case .installed:
        return .array(installedApps(in: ["/Applications", "/System/Applications", home + "/Applications"]))
    case let .launch(target):
        return try launch(target)
    case let .activate(target):
        if let app = running(target).first(where: \.isActive) {
            return json(app)
        }
        return try launch(target)
    case let .quit(target):
        return .object(["asked": .number(Double(running(target).count(where: { $0.terminate() })))])
    }
}

func installedApps(in folders: [String]) -> [JSON] {
    let files = FileManager.default
    func bundles(in folder: String, depth: Int) -> [String] {
        let paths = ((try? files.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.map { folder + "/" + $0 }
        return paths.flatMap { path -> [String] in
            if path.hasSuffix(".app") {
                return [path]
            }
            var directory: ObjCBool = false
            guard depth > 0, files.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return [] }
            return bundles(in: path, depth: depth - 1)
        }
    }
    var seen: Set<String> = []
    var apps: [(name: String, json: JSON)] = []
    for path in folders.flatMap({ bundles(in: $0, depth: 1) }) {
        let info = CFBundleCopyInfoDictionaryInDirectory(URL(fileURLWithPath: path) as CFURL) as NSDictionary?
        let id = info?[kCFBundleIdentifierKey as String] as? String
        if let id, !seen.insert(id.lowercased()).inserted {
            continue
        }
        let shown = files.displayName(atPath: path)
        let name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
        apps.append((name, .object(["name": .string(name), "path": .string(path), "app": id.map(JSON.string) ?? .null])))
    }
    return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.json)
}

private func running(_ target: AppTarget) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
        switch target {
        case let .bundle(id): app.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame
        case let .path(path): app.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    }
}

private func launch(_ target: AppTarget) throws -> JSON {
    let url: URL
    switch target {
    case let .bundle(id):
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { throw HostFailure("no app with bundle id \(id)") }
        url = found
    case let .path(path):
        guard FileManager.default.fileExists(atPath: path) else { throw HostFailure("no app at \(path)") }
        url = URL(fileURLWithPath: path)
    }
    let done = DispatchSemaphore(value: 0)
    var result: Result<NSRunningApplication, Error> = .failure(HostFailure("\(target) did not launch within 10 s"))
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
        if let app {
            result = .success(app)
        } else if let error {
            result = .failure(HostFailure(error.localizedDescription))
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
    return try json(result.get())
}

private final class AppsTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private var observations: [Observation] = []

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ]
        observations = names.map { name in Observation(NSWorkspace.shared.notificationCenter, name) { [weak self] in self?.send(Trace("apps")) } }
        send(Trace("apps-start"))
    }

    private func send(_ trace: Trace) {
        let workspace = NSWorkspace.shared
        publish(.object([
            "frontmost": workspace.frontmostApplication.map(json) ?? .null,
            "running": .array(workspace.runningApplications.filter { $0.activationPolicy == .regular }.map(json)),
        ]), trace)
    }
}
