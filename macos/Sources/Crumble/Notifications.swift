import AppKit
import Foundation
import UserNotifications

/// One event from the server's activity stream.
struct ActivityEvent: Decodable, Sendable {
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

    func start(model: AppModel) {
        self.model = model
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ event: ActivityEvent, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["type": event.type, "agentId": event.agentId]
        // Replies from one bot replace each other, so a busy bot leaves one notification.
        let id = "reply-\(event.agentId)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let agentID = info["agentId"] as? String
        await MainActor.run {
            NSApp.activate()
            guard let model else { return }
            if let agentID {
                model.selectAgent(agentID)
            }
        }
    }
}
