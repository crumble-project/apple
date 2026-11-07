import apfelkern
import AudioToolbox
import Foundation
import UIKit
import UserNotifications

struct NotificationContext {
  var appActive: Bool
  var route: Route?
}

func notification(for event: ActivityEvent, in context: NotificationContext) -> (
  title: String, body: String
)? {
  switch event.type {
  case "reply":
    guard event.origin != "bot" else { return nil }
    let text = preview(event.preview ?? "")
    if let group = event.groupId {
      if context.appActive, context.route == .group(group) { return nil }
      return (event.groupTitle, text.isEmpty ? "Replied" : text)
    }
    if context.appActive, context.route == .agent(event.agentId) { return nil }
    return (event.agentName, text.isEmpty ? "Replied" : text)
  default:
    return nil
  }
}

/// Keeps the delegate installed before launch completes, including a launch from a push tap.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = Notifier.shared
    return true
  }

  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushController.shared.receivedToken(deviceToken)
  }

  func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    PushController.shared.registrationFailed()
  }
}

/// A Sendable snapshot of the untyped system payload, parsed before crossing actors.
struct NotificationPayload: Sendable {
  var event: ActivityEvent?
  var local: Bool
  var localServerURL: String?

  init(userInfo: [AnyHashable: Any]) {
    local = userInfo["crumbleLocal"] as? Bool == true
    localServerURL = userInfo["localServerURL"] as? String
    if JSONSerialization.isValidJSONObject(userInfo),
      let data = try? JSONSerialization.data(withJSONObject: userInfo),
      let decoded = try? JSONDecoder().decode(ActivityEvent.self, from: data),
      decoded.type == "reply", !decoded.agentId.isEmpty,
      local || (decoded.serverId?.isEmpty == false && decoded.eventId?.isEmpty == false) {
      event = decoded
    }
  }

  func matches(serverID: String?, serverURL: String?) -> Bool {
    guard let event else { return false }
    if local, let localServerURL { return localServerURL == serverURL }
    return serverID != nil && event.serverId == serverID
  }
}

/// Retains a cold-launch destination until both server identity and agents are available.
struct NotificationTapRouter {
  enum Resolution: Equatable { case open(String), openGroup(String), openDesktop(String), differentServer }
  private var pending: NotificationPayload?

  mutating func queue(_ payload: NotificationPayload) {
    guard let event = payload.event, event.origin != "bot" else { return }
    pending = payload
  }

  mutating func resolve(
    serverID: String?, serverURL: String?, agentIDs: [String]
  ) -> Resolution? {
    guard let payload = pending, let event = payload.event else { return nil }
    guard payload.local || serverID != nil else { return nil }
    guard payload.matches(serverID: serverID, serverURL: serverURL) else {
      pending = nil
      return .differentServer
    }
    // A group outlives the bot that answered in it, so wait only for the bot list to load.
    if let group = event.groupId {
      guard !agentIDs.isEmpty else { return nil }
      pending = nil
      return .openGroup(group)
    }
    guard agentIDs.contains(event.agentId) else { return nil }
    pending = nil
    // A desktop job's report usually needs the owner on the bot desktop.
    return event.origin == DesktopJob.originKind ? .openDesktop(event.agentId) : .open(event.agentId)
  }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifier()
  weak var model: AppModel?
  private let center = UNUserNotificationCenter.current()
  private let push = PushController.shared
  private var tapRouter = NotificationTapRouter()
  private var history = NotificationHistory(keys: UserDefaults.standard.stringArray(forKey: "push.seen") ?? [])
  private var started = false
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid

  func start(model: AppModel) {
    self.model = model
    center.delegate = self
    // Isolated test launches must not request system permission or register a real device.
    guard ProcessInfo.processInfo.environment["CRUMBLE_SKIP_KEYCHAIN"] != "1",
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    else { return }
    started = true
    push.didUpdate = { [weak self] in self?.routePendingTap() }
    connectionChanged()
    refreshAuthorization(requestIfNeeded: true)
  }

  func connectionChanged() {
    guard started else { return }
    push.setConnection(model?.client)
    updatePresence()
  }

  /// Unregisters this device while the session still works, before it's signed out.
  func releaseConnection() async {
    guard started else { return }
    push.setConnection(nil)
    await push.waitForSync()
  }

  func setEnabled(_ enabled: Bool) {
    push.setEnabled(enabled)
    if enabled { refreshAuthorization(requestIfNeeded: true) }
  }

  func refreshAuthorization(requestIfNeeded: Bool = false) {
    guard started else { return }
    Task {
      var settings = await center.notificationSettings()
      // Also for installs that allowed notifications before the app used badges.
      if push.enabled, requestIfNeeded, settings.authorizationStatus != .denied, settings.badgeSetting != .enabled {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        settings = await center.notificationSettings()
      }
      let authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
      push.setAuthorized(authorized)
      push.setBadgesOff(authorized && settings.badgeSetting != .enabled)
      if authorized, push.enabled { UIApplication.shared.registerForRemoteNotifications() }
    }
  }

  func updatePresence(active: Bool? = nil) {
    guard started else { return }
    let isActive = active ?? (UIApplication.shared.applicationState == .active)
    let agentID: String? = if case .agent(let id) = model?.route { id } else { nil }
    push.setPresence(active: isActive, agentID: agentID)
    if !isActive, backgroundTask == .invalid {
      // A finite grace period lets the presence update finish as iOS suspends the app.
      backgroundTask = UIApplication.shared.beginBackgroundTask(
        withName: "Update notification presence"
      ) { [weak self] in
        Task { @MainActor in self?.finishPresenceUpdate() }
      }
      Task {
        await push.waitForSync()
        finishPresenceUpdate()
      }
    }
  }

  private func finishPresenceUpdate() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  func routePendingTap() {
    guard let model else { return }
    switch tapRouter.resolve(
      serverID: push.serverID, serverURL: model.client?.baseURL, agentIDs: model.agents.map(\.id)) {
    case .open(let agentID): model.selectAgent(agentID)
    case .openGroup(let groupID): model.openNotificationGroup(groupID)
    case .openDesktop(let agentID):
      model.selectAgent(agentID)
      model.botDesktop = BotDesktopTarget(id: agentID)
    case .differentServer: model.showNotice("This notification belongs to a different server.")
    case nil: break
    }
  }

  private func remember(_ event: ActivityEvent) -> Bool {
    guard let eventID = event.eventId, let serverID = event.serverId else { return true }
    let inserted = history.insert(serverID: serverID, eventID: eventID)
    if inserted { UserDefaults.standard.set(history.keys, forKey: "push.seen") }
    return inserted
  }

  func post(_ event: ActivityEvent, title: String, body: String) {
    guard push.enabled, !push.remoteDelivery, remember(event) else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = NoticeKind(event).soundFile.map { UNNotificationSound(named: .init($0)) } ?? .default
    content.userInfo = Self.localPayload(event, serverURL: model?.client?.baseURL ?? "")
    let identifier = event.groupId.map { "reply-group-\($0)" } ?? "reply-\(event.agentId)"
    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }

  /// Carries every field `NotificationPayload` decodes, so a local notification shows and routes like a push.
  nonisolated static func localPayload(_ event: ActivityEvent, serverURL: String) -> [AnyHashable: Any] {
    var info: [AnyHashable: Any] = [
      "type": event.type, "agentId": event.agentId, "agentName": event.agentName,
      "crumbleLocal": true, "localServerURL": serverURL
    ]
    info["eventId"] = event.eventId
    info["entryId"] = event.entryId
    info["serverId"] = event.serverId
    info["createdAt"] = event.createdAt
    info["origin"] = event.origin
    info["preview"] = event.preview
    info["groupId"] = event.groupId
    info["groupName"] = event.groupName
    info["jobName"] = event.jobName
    info["waitingFor"] = event.waitingFor
    return info
  }

  private func presentation(for payload: NotificationPayload) -> UNNotificationPresentationOptions {
    guard push.enabled, payload.matches(serverID: push.serverID, serverURL: model?.client?.baseURL),
      let event = payload.event
    else { return [] }
    if !payload.local, !remember(event) { return [] }
    guard notification(for: event, in: NotificationContext(appActive: true, route: model?.route)) != nil
    else { return [] }
    // A push names the system sound and only the server can change that, so while the app is open it plays the cue.
    if !payload.local, let file = NoticeKind(event).soundFile {
      playNoticeSound(file)
      return [.banner]
    }
    return [.banner, .sound]
  }

  private func playNoticeSound(_ file: String) {
    guard let url = Bundle.main.url(forResource: file, withExtension: nil) else { return }
    var sound: SystemSoundID = 0
    guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return }
    AudioServicesPlaySystemSoundWithCompletion(sound) { AudioServicesDisposeSystemSoundID(sound) }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let payload = NotificationPayload(userInfo: notification.request.content.userInfo)
    return await presentation(for: payload)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let payload = NotificationPayload(userInfo: response.notification.request.content.userInfo)
    await handleTap(payload)
  }

  private func handleTap(_ payload: NotificationPayload) {
    guard let event = payload.event, event.origin != "bot" else { return }
    _ = remember(event)
    tapRouter.queue(payload)
    routePendingTap()
  }
}
