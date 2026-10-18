import apfelkern
import Foundation
import Observation

struct PushServer: Decodable, Sendable {
  var serverId: String
  var transports: Transports
  struct Transports: Decodable, Sendable { var apns: Bool; var fcm: Bool }
}

struct PushDevice: Codable, Equatable, Sendable {
  var platform = "ios"
  var transport = "apns"
  var token: String
  var environment: String
  var bundleId: String
  var enabled = true
}

struct PushRegistration: Decodable, Sendable {
  var serverId: String
  var remoteDelivery: Bool
}

struct PushPresence: Encodable, Sendable {
  var active: Bool
  var agentId: String?

  // The contract requires an explicit null when no chat is visible.
  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(active, forKey: .active)
    if let agentId { try values.encode(agentId, forKey: .agentId) } else { try values.encodeNil(forKey: .agentId) }
  }
  private enum CodingKeys: CodingKey { case active, agentId }
}

extension APIClient {
  func pushServer() async throws -> PushServer { try await call("GET", "/v1/push") }

  func registerPush(_ id: String, device: PushDevice) async throws -> PushRegistration {
    try await call("PUT", "/v1/push/devices/\(id)", body: device)
  }

  func unregisterPush(_ id: String) async throws {
    _ = try await send("DELETE", "/v1/push/devices/\(id)")
  }

  func pushPresence(_ id: String, presence: PushPresence) async throws {
    _ = try await send("PUT", "/v1/push/devices/\(id)/presence", body: presence)
  }
}

/// A bounded, persisted set shared by stream and remote delivery, scoped to server identity.
struct NotificationHistory {
  private(set) var keys: [String]
  let limit: Int

  init(keys: [String] = [], limit: Int = 256) {
    self.keys = Array(keys.suffix(limit))
    self.limit = limit
  }

  mutating func insert(serverID: String, eventID: String) -> Bool {
    let key = serverID + ":" + eventID
    guard !keys.contains(key) else { return false }
    keys.append(key)
    if keys.count > limit { keys.removeFirst(keys.count - limit) }
    return true
  }
}

/// Serializes token changes and connection cleanup so an old request cannot overwrite a new one.
@MainActor @Observable
final class PushController {
  static let shared = PushController()
  private(set) var enabled: Bool
  private(set) var authorized = false
  private var authorizationKnown = false
  private(set) var serverID: String?
  private(set) var remoteDelivery = false
  private(set) var status = "Waiting for notification permission."
  private(set) var deviceToken: String?

  private let defaults: UserDefaults
  private let persistCredentials: Bool
  let installationID: String
  private let bundleID: String
  private let environment: String
  private var client: APIClient?
  private var active = false
  private var agentID: String?
  private var revision = 0
  private var worker: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var registered: Connection?
  private var cleanup: [Connection] = []
  var didUpdate: (() -> Void)?

  private struct Connection: Codable, Equatable {
    var url: String
    var token: String
    var installationID: String
    var remoteDelivery: Bool?
  }
  private struct StoredConnections: Codable {
    var registered: Connection?
    var cleanup: [Connection]
  }

  init(
    defaults: UserDefaults = .standard, persistCredentials: Bool = true,
    bundleID: String = Bundle.main.bundleIdentifier ?? "dev.crumble-project.ios",
    environment: String = Bundle.main.object(forInfoDictionaryKey: "CrumbleAPNSEnvironment") as? String
      ?? "development"
  ) {
    self.defaults = defaults
    self.persistCredentials = persistCredentials
    self.bundleID = bundleID
    self.environment = environment
    enabled = defaults.object(forKey: "push.enabled") as? Bool ?? true
    installationID = defaults.string(forKey: "push.installationID") ?? UUID().uuidString.lowercased()
    defaults.set(installationID, forKey: "push.installationID")
    if persistCredentials, let stored = Keychain.read("push-connections"),
      let data = stored.data(using: .utf8),
      let state = try? JSONDecoder().decode(StoredConnections.self, from: data) {
      registered = state.registered
      cleanup = state.cleanup
    }
  }

  func setConnection(_ candidate: APIClient?) {
    let next = candidate.flatMap { $0.token.isEmpty ? nil : $0 }
    if let registered,
      registered.url != next?.baseURL || registered.token != next?.token
        || registered.installationID != installationID {
      enqueueCleanup(registered)
      self.registered = nil
    }
    client = next
    serverID = nil
    // Only this server's registrations suppress local alerts. During a credential change its
    // previous registration may still deliver until DELETE succeeds. Another server cannot.
    let currentRegistrations = cleanup + (registered.map { [$0] } ?? [])
    remoteDelivery = enabled && currentRegistrations.contains {
      $0.url == next?.baseURL && $0.remoteDelivery != false
    }
    changed()
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    defaults.set(value, forKey: "push.enabled")
    if !value { remoteDelivery = false }
    changed()
  }

  func setAuthorized(_ value: Bool) {
    authorized = value
    authorizationKnown = true
    if !value { remoteDelivery = false }
    changed()
  }

  func receivedToken(_ token: Data) {
    deviceToken = token.map { String(format: "%02x", $0) }.joined()
    changed()
  }

  func registrationFailed() {
    status = "APNs registration failed. Check signing and network access; retry on return to the app."
  }

  func setPresence(active: Bool, agentID: String?) {
    self.active = active
    self.agentID = active ? agentID : nil
    heartbeat?.cancel()
    heartbeat = nil
    if active {
      heartbeat = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
          guard let self else { return }
          self.changed()
        }
      }
    }
    changed()
  }

  /// Also used by tests to wait for serialized network reconciliation.
  func waitForSync() async { await worker?.value }

  private func changed() {
    revision += 1
    persist()
    guard worker == nil else { return }
    worker = Task {
      var processed = -1
      while processed != revision {
        processed = revision
        await synchronize(version: processed)
      }
      worker = nil
      didUpdate?()
    }
  }

  private func enqueueCleanup(_ connection: Connection) {
    if !cleanup.contains(connection) { cleanup.append(connection) }
  }

  private func persist() {
    guard persistCredentials,
      let data = try? JSONEncoder().encode(StoredConnections(registered: registered, cleanup: cleanup)),
      let value = String(data: data, encoding: .utf8)
    else { return }
    try? Keychain.write("push-connections", value: value)
  }

  private func removePreviousRegistrations(version: Int) async -> Bool {
    for old in cleanup {
      do {
        // Reuse the current session for testability, without changing the old credentials.
        let api = APIClient(baseURL: old.url, token: old.token, session: client?.session ?? .shared)
        try await api.unregisterPush(old.installationID)
        cleanup.removeAll { $0 == old }
        persist()
      } catch { /* Keep the old credential in Keychain and retry on the next heartbeat/launch. */ }
      guard version == revision else { return false }
    }
    return true
  }

  private var readyToRegister: Bool {
    guard enabled, authorized else {
      status = !enabled ? "Notifications are off."
        : authorizationKnown ? "Notifications are off in iOS Settings."
        : "Waiting for notification permission."
      if !cleanup.isEmpty { status += " Previous server removal is pending and will retry." }
      return false
    }
    guard cleanup.isEmpty else {
      status = "Previous server removal is pending. Remote setup will retry while the app is active."
      return false
    }
    guard deviceToken != nil else {
      status = "Waiting for APNs device registration."
      return false
    }
    return true
  }

  private func synchronize(version: Int) async {
    guard await removePreviousRegistrations(version: version) else { return }
    guard let client else { status = "Connect to a server to enable push notifications."; return }
    do {
      // Disabling must still remove a registration if capability discovery is unavailable.
      if !enabled || (authorizationKnown && !authorized), let registered {
        try await client.unregisterPush(registered.installationID)
        guard version == revision else { return }
        self.registered = nil
        remoteDelivery = false
        persist()
      }
      let identity = try await client.pushServer()
      guard version == revision else { return }
      serverID = identity.serverId
      guard readyToRegister, let deviceToken else { return }
      // Persist before sending: a server switch or crash during PUT still leaves cleanup work.
      registered = Connection(url: client.baseURL, token: client.token, installationID: installationID)
      persist()
      let response = try await client.registerPush(
        installationID,
        device: PushDevice(token: deviceToken, environment: environment, bundleId: bundleID))
      guard version == revision else { return }
      guard response.serverId == identity.serverId else {
        remoteDelivery = false
        status = "Server identity changed. Reconnect before using push notifications."
        return
      }
      remoteDelivery = response.remoteDelivery
      registered?.remoteDelivery = response.remoteDelivery
      persist()
      status = response.remoteDelivery
        ? "Push notifications are ready."
        : "Server push delivery is not configured. Alerts work while the app is open."
      try await client.pushPresence(
        installationID, presence: PushPresence(active: active, agentId: active ? agentID : nil))
    } catch {
      guard version == revision else { return }
      status = "Push setup could not reach the server. It will retry when the app is active."
    }
  }
}
