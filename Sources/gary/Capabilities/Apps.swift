import AppKit
import GaryCore

extension Capability {
    static let apps = Capability(
        name: "apps",
        summary: "The frontmost app and the running apps. Launch, activate, and quit apps by bundle id.",
        types: """
        declare namespace Gary {
          type Apps = { frontmost: App | null; running: App[] }
          type App = { app: string | null; name: string; pid: number; path: string | null; active: boolean; hidden: boolean }
          interface Host { apps: AppsApi }
          interface AppsApi {
            launch(bundle: string): Promise<App>;
            activate(bundle: string): Promise<App>;
            quit(bundle: string): Promise<{ asked: number }>;
          }
        }
        """,
        example: """
        export default {
          render(state) {
            return { type: "text", text: state.apps?.frontmost?.name ?? "", action: "terminal" };
          },
          onAction(action) {
            if (action === "terminal") host.apps.activate("com.apple.Terminal").catch(() => host.apps.launch("com.apple.Terminal"));
          },
        } satisfies Gary.BarWidget;
        """,
        install: { host, plugin in
            plugin.installAPI(host, "apps", AppsRequest.methods) { call in
                let request = try AppsRequest.parse(call)
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
    case let .launch(bundle):
        return try launch(bundle)
    case let .activate(bundle):
        guard let app = running(bundle).first else { return try launch(bundle) }
        app.activate()
        return json(app)
    case let .quit(bundle):
        return .object(["asked": .number(Double(running(bundle).count(where: { $0.terminate() })))])
    }
}

private func running(_ bundle: String) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.caseInsensitiveCompare(bundle) == .orderedSame }
}

private func launch(_ bundle: String) throws -> JSON {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw HostFailure("no app with bundle id \(bundle)") }
    let done = DispatchSemaphore(value: 0)
    var result: Result<NSRunningApplication, Error> = .failure(HostFailure("\(bundle) did not launch within 10 s"))
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
