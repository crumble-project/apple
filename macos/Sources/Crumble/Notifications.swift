import AppKit
import Foundation
import UserNotifications

/// One event from the server's activity stream.
struct ActivityEvent: Codable, Sendable {
    var eventId: String?
    var serverId: String?
    var createdAt: String?
    var type: String
    var agentId: String
    var agentName: String
    var entryId: String?
    var origin: String?
    var preview: String?
    var lastMessage: String?
}

/// What the owner is looking at, which decides whether an event is worth a notification.
struct NotificationContext {
    var appActive: Bool
    var route: Route?
}

/// A finished reply notifies unless its chat is on screen, and delegated work stays quiet because
/// the delegating bot reports back itself.
func notification(for event: ActivityEvent, in context: NotificationContext) -> (title: String, body: String)? {
    switch event.type {
    case "reply":
        guard event.origin != "bot" else { return nil }
        if context.appActive, context.route == .agent(event.agentId) { return nil }
        let text = preview(event.preview ?? "")
        return (event.agentName, text.isEmpty ? "Replied" : text)
    default:
        return nil
    }
}

/// Posts notifications and routes a click back into the window. Notifications need a bundle
/// identifier, so a binary started with `swift run` posts none.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var model: AppModel?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func installDelegate() { center?.delegate = self }

    func start(model: AppModel) {
        self.model = model
        guard let center else { return }
        center.delegate = self
        PushNotifications.shared.start(model: model)
    }

    func post(_ event: ActivityEvent, title: String, body: String) {
        guard let center, PushNotifications.shared.shouldPostLocal(event) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "type": event.type, "agentId": event.agentId, "local": true,
            "serverURL": model?.client?.baseURL ?? ""
        ]
        // Replies from one bot replace each other, so a busy bot leaves one notification.
        let id = "reply-\(event.agentId)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async
        -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if info["local"] as? Bool == true {
            let url = info["serverURL"] as? String
            let agentId = info["agentId"] as? String
            return await MainActor.run {
                guard PushNotifications.shared.enabled, self.model?.client?.baseURL == url else { return [] }
                if NSApp.isActive, let agentId, self.model?.route == .agent(agentId) { return [] }
                return [.banner, .sound]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: info),
            let event = try? JSONDecoder().decode(ActivityEvent.self, from: data)
        else { return [] }
        return await PushNotifications.shared.presentation(for: event)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if info["local"] as? Bool == true {
            let agentID = info["agentId"] as? String
            let serverURL = info["serverURL"] as? String
            guard let agentID, let serverURL else { return }
            await PushNotifications.shared.openLocal(agentId: agentID, serverURL: serverURL)
        } else if let data = try? JSONSerialization.data(withJSONObject: info),
            let event = try? JSONDecoder().decode(ActivityEvent.self, from: data) {
            await PushNotifications.shared.open(event)
        }
    }
}
