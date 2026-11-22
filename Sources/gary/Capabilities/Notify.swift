import Foundation
import GaryCore
import UserNotifications

extension Capability {
    static let notify = Capability(
        name: "notify",
        summary: """
        Post a macOS notification from Gary. Notification Center shows it as a banner and keeps it in its list, \
        and a Focus silences it, as for any app. The promise resolves once macOS has it. For a card that Gary draws \
        and that reports a click, use `toast`.
        """,
        types: """
        declare namespace Gary {
          type NotificationPost = { title: string; subtitle?: string; body?: string; sound?: boolean }
          interface Host { notify: { post(notification: NotificationPost): Promise<null> } }
        }
        """,
        example: """
        let warned = false;

        export default {
          onTopic({ topic, value }) {
            if (topic !== "battery" || value.percent === null) return;
            if (value.percent > 10 || value.charging) warned = false;
            else if (!warned) {
              warned = true;
              host.notify.post({ title: "Battery low", body: `${value.percent}% left`, sound: true }).catch((error) => host.log(String(error)));
            }
          },
        } satisfies Gary.Service;
        """,
        permissions: [.notifications],
        install: { host, plugin in
            plugin.installAPI(host, "notify", NotifyRequest.methods) { call in
                let request = try NotifyRequest.parse(call)
                return .pending { finish in NotificationPoster.post(request, finish) }
            }
        },
    )
}

enum NotificationPoster {
    static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    static var authorization: UNAuthorizationStatus? {
        guard let center else { return nil }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: UNAuthorizationStatus?
        center.getNotificationSettings { settings in
            status = settings.authorizationStatus
            done.signal()
        }
        return done.wait(timeout: .now() + 1) == .success ? status : nil
    }

    static func request() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in log("notifications: \(granted ? "allowed" : "refused")") }
    }

    static func post(_ request: NotifyRequest, _ finish: @escaping (Result<JSON, Error>) -> Void) {
        guard let center else {
            finish(.failure(HostFailure("macOS delivers notifications only from Gary.app, not from a bare gary binary")))
            return
        }
        center.getNotificationSettings { settings in
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
                finish(.failure(HostFailure(missingGrant(.notifications, "notify"))))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.subtitle = request.subtitle ?? ""
            content.body = request.body ?? ""
            content.sound = request.sound ? .default : nil
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                finish(error.map { .failure($0) } ?? .success(.null))
            }
        }
    }
}
