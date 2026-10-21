import apfelkern
import AppKit
import Foundation
import Observation
import UserNotifications

/// What the owner is looking at, which decides whether an event is worth a notification.
struct NotificationContext {
    /// The app is active and its main window is on screen, not closed, hidden, or minimized.
    var windowOnScreen: Bool
    var route: Route?
}

/// A finished reply notifies unless its chat is on screen, and delegated work stays quiet because
/// the delegating bot reports back itself. A group answer names its group and notifies unless that
/// group is on screen. A bot's answer to a job's report names the job.
func notification(for event: ActivityEvent, in context: NotificationContext) -> (title: String, body: String)? {
    switch event.type {
    case "reply":
        guard event.origin != "bot" else { return nil }
        let text = preview(event.preview ?? "")
        if let group = event.groupId {
            if context.windowOnScreen, context.route == .group(group) { return nil }
            return ("\(event.agentName) in \(event.groupName ?? "a group chat")", text.isEmpty ? "Replied" : text)
        }
        if context.windowOnScreen, context.route == .agent(event.agentId) { return nil }
        guard let kind = JobKind.allCases.first(where: { $0.originKind == event.origin }) else {
            return (event.agentName, text.isEmpty ? "Replied" : text)
        }
        let job = [kind.noun, event.jobName].compactMap(\.self).joined(separator: " ")
        return ("\(event.agentName) · \(job)", text.isEmpty ? "Replied" : text)
    default:
        return nil
    }
}

@MainActor func mainWindowOnScreen() -> Bool {
    guard let app = NSApp, app.isActive else { return false }
    return app.windows.contains {
        ($0.identifier?.rawValue == "main" || $0.title == "Crumble") && $0.isVisible && !$0.isMiniaturized
            && $0.occlusionState.contains(.visible)
    }
}

/// Replies already notified, keyed by server URL because servers without push report no server ID.
struct NotificationLedger {
    var keys: [String] = []
    mutating func insert(server: String, event: String) -> Bool {
        let key = server + ":" + event
        guard !keys.contains(key) else { return false }
        keys.append(key)
        if keys.count > 512 { keys.removeFirst(keys.count - 512) }
        return true
    }
}

/// The bot chat or group chat a notification opens.
struct NotificationTarget: Equatable {
    var serverURL: String
    var agentId: String
    var groupId: String?
    /// An answer to a desktop job's report, which likely needs the owner on the bot desktop.
    var desktop = false

    var route: Route { groupId.map(Route.group) ?? .agent(agentId) }
}

/// Posts local notifications for the activity stream and routes a click back into the window.
/// Delivery needs a bundle identifier, so a binary started with `swift run` posts none.
@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "push-enabled") }
    }
    private(set) var authorized = false
    var status: String {
        if !canDeliver { return "Notifications need the app bundle" }
        if !enabled { return "Notifications disabled" }
        if !authorized { return "Notifications disabled in System Settings" }
        return "Local notifications"
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var openMainWindow: (() -> Void)? { didSet { routePendingTap() } }
    /// Set before `openMainWindow`, which routes a tap that launched the app.
    @ObservationIgnored var openBotDesktop: ((String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let canDeliver: Bool
    @ObservationIgnored private let usesSystemCenter: Bool
    @ObservationIgnored private let deliver: (UNNotificationRequest) -> Void
    @ObservationIgnored private let permission: () async -> Bool
    @ObservationIgnored private let windowOnScreen: @MainActor () -> Bool
    @ObservationIgnored private var ledger: NotificationLedger
    @ObservationIgnored private var pendingTap: NotificationTarget?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        canDeliver: Bool = Bundle.main.bundleIdentifier != nil,
        deliver: ((UNNotificationRequest) -> Void)? = nil,
        permission: (() async -> Bool)? = nil,
        windowOnScreen: @escaping @MainActor () -> Bool = mainWindowOnScreen
    ) {
        self.defaults = defaults
        self.canDeliver = canDeliver
        usesSystemCenter = canDeliver && deliver == nil
        self.deliver = deliver ?? { UNUserNotificationCenter.current().add($0) }
        self.permission = permission ?? Self.requestPermission
        self.windowOnScreen = windowOnScreen
        enabled = defaults.object(forKey: "push-enabled") as? Bool ?? true
        ledger = NotificationLedger(keys: defaults.stringArray(forKey: "push-seen-events") ?? [])
    }

    private static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Installs the delegate before launch finishes, so a click that launched the app is delivered.
    func installDelegate() {
        if usesSystemCenter { UNUserNotificationCenter.current().delegate = self }
    }

    func start(model: AppModel) {
        self.model = model
        removeRetiredPushState()
        routePendingTap()
        guard canDeliver, observer == nil else { return }
        installDelegate()
        // Permission can change in System Settings while the app runs.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAuthorization() }
        }
        Task { await refreshAuthorization() }
    }

    /// APNs builds stored an installation, a server binding, and old server tokens for unregistering.
    private func removeRetiredPushState() {
        for key in ["push-installation-id", "push-remote-server-url", "push-remote-server-id"] {
            defaults.removeObject(forKey: key)
        }
        if usesSystemCenter { Keychain.delete("push-pending-removals") }
    }

    func refreshAuthorization() async {
        authorized = await permission()
    }

    func post(_ event: ActivityEvent, title: String, body: String, serverURL: String) {
        guard canDeliver, enabled else { return }
        if let id = event.eventId?.nilIfEmpty ?? event.entryId?.nilIfEmpty {
            guard ledger.insert(server: serverURL, event: id) else { return }
            defaults.set(ledger.keys, forKey: "push-seen-events")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [String: Any] = ["agentId": event.agentId, "serverURL": serverURL]
        if let group = event.groupId { info["groupId"] = group }
        if event.origin == DesktopJob.originKind { info["desktop"] = true }
        content.userInfo = info
        // Replies from one bot, or in one group, replace each other, so a busy chat leaves one notification.
        let id = event.groupId.map { "reply-\(serverURL)-group-\($0)" } ?? "reply-\(serverURL)-\(event.agentId)"
        deliver(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The stream decided to post while the owner may have opened the chat since.
    func shouldPresent(_ target: NotificationTarget) -> Bool {
        guard enabled, let model, model.client?.baseURL == target.serverURL else { return false }
        return !(windowOnScreen() && model.route == target.route)
    }

    func open(_ target: NotificationTarget) {
        pendingTap = target
        routePendingTap()
    }

    private func routePendingTap() {
        guard let model, let target = pendingTap else { return }
        pendingTap = nil
        NSApp?.activate()
        openMainWindow?()
        guard model.client?.baseURL == target.serverURL else {
            model.errorText = "This notification is from \(target.serverURL). Connect to that server to open it."
            return
        }
        if let group = target.groupId {
            model.openNotificationGroup(group)
        } else {
            model.openNotificationChat(target.agentId)
            if target.desktop { openBotDesktop?(target.agentId) }
        }
    }

    nonisolated static func target(_ info: [AnyHashable: Any]) -> NotificationTarget? {
        guard let serverURL = info["serverURL"] as? String, let agentId = info["agentId"] as? String else {
            return nil
        }
        return NotificationTarget(
            serverURL: serverURL, agentId: agentId, groupId: info["groupId"] as? String,
            desktop: info["desktop"] as? Bool ?? false)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard let target = Self.target(notification.request.content.userInfo) else { return [] }
        return await MainActor.run { shouldPresent(target) ? [.banner, .sound] : [] }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let target = Self.target(response.notification.request.content.userInfo) else { return }
        await MainActor.run { open(target) }
    }
}
