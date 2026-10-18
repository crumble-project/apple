import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  private func pushDefaults() -> UserDefaults {
    let suite = "Crumble.PushNotificationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func pushDeviceBody(_ request: URLRequest) throws -> PushDevice {
    try JSONDecoder().decode(PushDevice.self, from: request.httpBody ?? Data())
  }

  @Test func staleMockSessionCannotPolluteNewSessionRequests() async throws {
    let stale = StubProtocol.client { _ in (200, "[]") }
    let current = StubProtocol.client(token: "current") { _ in (200, "[]") }
    do {
      _ = try await stale.agents()
      Issue.record("An old session must not consume the new session's canned response.")
    } catch let error as APIError {
      #expect(error.statusCode == 401)
    }
    #expect(StubProtocol.requests.isEmpty)
    _ = try await current.agents()
    #expect(StubProtocol.requests.count == 1)
    #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer current")
  }

  @Test func pushAPIUsesWireContractForGetPutDeleteAndPresence() async throws {
    let client = StubProtocol.client(token: "bearer") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/install-1"):
        (200, #"{"serverId":"server-a","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/install-1/presence"),
        ("DELETE", "/v1/push/devices/install-1"):
        (204, "")
      default: (404, "")
      }
    }

    let identity = try await client.pushServer()
    #expect(identity.serverId == "server-a")
    #expect(identity.transports.apns)

    let registration = try await client.registerPush(
      "install-1",
      device: PushDevice(token: "aabb", environment: "development", bundleId: "dev.crumble"))
    #expect(registration.remoteDelivery)

    try await client.pushPresence("install-1", presence: PushPresence(active: true, agentId: "a1"))
    try await client.pushPresence("install-1", presence: PushPresence(active: false, agentId: nil))
    try await client.unregisterPush("install-1")

    #expect(StubProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
      "GET /v1/push",
      "PUT /v1/push/devices/install-1",
      "PUT /v1/push/devices/install-1/presence",
      "PUT /v1/push/devices/install-1/presence",
      "DELETE /v1/push/devices/install-1",
    ])
    let registrationRequest = StubProtocol.requests[1]
    #expect(registrationRequest.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")
    #expect(try pushDeviceBody(registrationRequest) == PushDevice(
      token: "aabb", environment: "development", bundleId: "dev.crumble"))
    let presence = try #require(StubProtocol.requests[2].httpBody)
    #expect(String(decoding: presence, as: UTF8.self).contains(#""agentId":"a1""#))
    let inactivePresence = try #require(StubProtocol.requests[3].httpBody)
    #expect(String(decoding: inactivePresence, as: UTF8.self).contains(#""agentId":null"#))
  }

  @MainActor @Test func receivedTokenEncodesBytesAsLowercaseHex() async {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    controller.receivedToken(Data([0x00, 0x0a, 0xab, 0xff]))
    await controller.waitForSync()
    #expect(controller.deviceToken == "000aabff")
  }

  @MainActor @Test func registrationIncludesTokenAndRemoteDelivery() async throws {
    let defaults = pushDefaults()
    let controller = PushController(defaults: defaults, persistCredentials: false)
    let client = StubProtocol.client(token: "auth") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"server-a","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setAuthorized(true)
    controller.receivedToken(Data([0x01, 0xfe]))
    controller.setConnection(client)
    await controller.waitForSync()

    #expect(controller.serverID == "server-a")
    #expect(controller.remoteDelivery)
    let registrationRequest = try #require(StubProtocol.requests.first { $0.httpMethod == "PUT" })
    #expect(try pushDeviceBody(registrationRequest).token == "01fe")
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
  }

  @MainActor @Test func switchingServersUnregistersOldCredentialsBeforeRegisteringNew() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let oldStub = StubProtocol.client(token: "old") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"old-server","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"old-server","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    let old = APIClient(baseURL: "http://old.test", token: "old", session: oldStub.session)
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(old)
    await controller.waitForSync()

    let beforeSwitch = StubProtocol.requests.count
    let newer = APIClient(baseURL: "http://new.test", token: "new", session: old.session)
    StubProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"):
        (204, "")
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"new-server","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"new-server","remoteDelivery":false}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setConnection(newer)
    await controller.waitForSync()

    let changed = StubProtocol.requests.dropFirst(beforeSwitch)
    #expect(changed.first?.httpMethod == "DELETE")
    #expect(changed.first?.value(forHTTPHeaderField: "Authorization") == "Bearer old")
    #expect(changed.contains { $0.httpMethod == "PUT" && $0.url?.host == "new.test" })
  }

  @MainActor @Test func tokenRotationUpsertsTheSameInstallation() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let client = StubProtocol.client(token: "auth") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"server-a","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setAuthorized(true)
    controller.receivedToken(Data([0x01]))
    controller.setConnection(client)
    await controller.waitForSync()
    controller.receivedToken(Data([0x02, 0xa0]))
    await controller.waitForSync()

    let registrations = StubProtocol.requests.filter { $0.httpMethod == "PUT" && $0.url?.path.hasSuffix(controller.installationID) == true }
    #expect(registrations.count == 2)
    #expect(try pushDeviceBody(registrations[0]).token == "01")
    #expect(try pushDeviceBody(registrations[1]).token == "02a0")
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
  }

  @MainActor @Test func mismatchedRegistrationIdentityDisablesRemoteDelivery() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let client = StubProtocol.client(token: "auth") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"server-other","remoteDelivery":true}"#)
      default: (404, "")
      }
    }
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(client)
    await controller.waitForSync()
    #expect(!controller.remoteDelivery)
    #expect(controller.status.contains("Server identity changed"))
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
  }

  @MainActor @Test func failedOldServerCleanupBlocksNewRegistrationUntilRetry() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let oldStub = StubProtocol.client(token: "old") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"old","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"old","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    let old = APIClient(baseURL: "http://old.test", token: "old", session: oldStub.session)
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(old)
    await controller.waitForSync()

    let newer = APIClient(baseURL: "http://new.test", token: "new", session: old.session)
    StubProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"):
        (503, "busy")
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"new","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"new","remoteDelivery":false}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setConnection(newer)
    await controller.waitForSync()
    #expect(!StubProtocol.requests.dropFirst(3).contains { $0.httpMethod == "PUT" && $0.url?.host == "new.test" })
    #expect(controller.status.contains("Previous server removal is pending"))
    #expect(!controller.remoteDelivery)

    StubProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"):
        (204, "")
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"new","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"new","remoteDelivery":false}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
    #expect(StubProtocol.requests.contains { $0.httpMethod == "PUT" && $0.url?.host == "new.test" })
    #expect(!controller.remoteDelivery)
  }

  @MainActor @Test func failedCleanupForSameServerPreservesRemoteUntilRetry() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let stub = StubProtocol.client(token: "old") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"same","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"same","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    let old = APIClient(baseURL: "http://same.test", token: "old", session: stub.session)
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(old)
    await controller.waitForSync()

    let newer = APIClient(baseURL: "http://same.test", token: "new", session: old.session)
    StubProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"):
        (503, "busy")
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"same","transports":{"apns":true,"fcm":false}}"#)
      default: (404, "")
      }
    }
    controller.setConnection(newer)
    await controller.waitForSync()
    #expect(controller.remoteDelivery)
    #expect(controller.status.contains("Previous server removal is pending"))

    StubProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"),
        ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"same","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"same","remoteDelivery":false}"#)
      default: (404, "")
      }
    }
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
    #expect(!controller.remoteDelivery)
  }

  @MainActor @Test func installationIDPersistsAcrossControllerRestart() async {
    let defaults = pushDefaults()
    let first = PushController(defaults: defaults, persistCredentials: false)
    let second = PushController(defaults: defaults, persistCredentials: false)
    #expect(!first.installationID.isEmpty)
    #expect(second.installationID == first.installationID)
  }

  @MainActor @Test func disablingPushUnregistersExistingDevice() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let client = StubProtocol.client(token: "auth") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"server-a","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(client)
    await controller.waitForSync()
    controller.setEnabled(false)
    await controller.waitForSync()

    #expect(!controller.enabled)
    #expect(!controller.remoteDelivery)
    #expect(StubProtocol.requests.contains { $0.httpMethod == "DELETE" })
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
  }

  @MainActor @Test func disablingPushCleansUpBeforeCapabilityDiscoveryFailure() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let client = StubProtocol.client(token: "auth") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":true,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"server-a","remoteDelivery":true}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(client)
    await controller.waitForSync()

    let beforeDisable = StubProtocol.requests.count
    StubProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("DELETE", "/v1/push/devices/\(controller.installationID)"):
        (204, "")
      case ("GET", "/v1/push"):
        (500, "temporarily unavailable")
      default: (404, "")
      }
    }
    controller.setEnabled(false)
    await controller.waitForSync()

    let changed = Array(StubProtocol.requests.dropFirst(beforeDisable))
    #expect(changed.first?.httpMethod == "DELETE")
    #expect(changed.dropFirst().contains { $0.httpMethod == "GET" && $0.url?.path == "/v1/push" })
    #expect(!controller.remoteDelivery)
  }

  @MainActor @Test func remoteDeliveryFalseLeavesLocalFallbackEnabled() async throws {
    let controller = PushController(defaults: pushDefaults(), persistCredentials: false)
    let client = StubProtocol.client(token: "auth") { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/push"):
        (200, #"{"serverId":"server-a","transports":{"apns":false,"fcm":false}}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)"):
        (200, #"{"serverId":"server-a","remoteDelivery":false}"#)
      case ("PUT", "/v1/push/devices/\(controller.installationID)/presence"):
        (204, "")
      default: (404, "")
      }
    }
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(client)
    await controller.waitForSync()
    #expect(!controller.remoteDelivery)
    #expect(controller.status.contains("Alerts work while the app is open"))
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
  }

  @Test func notificationPayloadRejectsMalformedAndWrongServerValues() {
    let malformed = NotificationPayload(userInfo: ["type": "reply", "agentId": "a1"])
    #expect(malformed.event == nil)

    let wrongServer = NotificationPayload(userInfo: [
      "type": "reply", "agentId": "a1", "agentName": "Atlas", "serverId": "other",
      "eventId": "evt-1", "origin": "user",
    ])
    #expect(wrongServer.event != nil)
    #expect(!wrongServer.matches(serverID: "server-a", serverURL: nil))
    #expect(wrongServer.matches(serverID: "other", serverURL: nil))
  }

  @Test func notificationHistoryIsBoundedAndServerScoped() {
    var history = NotificationHistory(limit: 2)
    let first = history.insert(serverID: "a", eventID: "same")
    let duplicate = history.insert(serverID: "a", eventID: "same")
    let otherServer = history.insert(serverID: "b", eventID: "same")
    let newest = history.insert(serverID: "a", eventID: "new")
    #expect(first)
    #expect(!duplicate)
    #expect(otherServer)
    #expect(newest)
    #expect(history.keys.count == 2)
    #expect(!history.keys.contains("a:same"))
    #expect(history.keys == ["b:same", "a:new"])
  }

  @Test func notificationTapRouterQueuesUntilIdentityAndAgentsThenOpensOnce() {
    let payload = NotificationPayload(userInfo: [
      "type": "reply", "agentId": "a1", "agentName": "Atlas", "serverId": "server-a",
      "eventId": "evt-1", "origin": "user",
    ])
    var router = NotificationTapRouter()
    router.queue(payload)
    #expect(router.resolve(serverID: nil, serverURL: "http://server", agentIDs: ["a1"]) == nil)
    #expect(router.resolve(serverID: "server-a", serverURL: "http://server", agentIDs: []) == nil)
    #expect(router.resolve(serverID: "server-a", serverURL: "http://server", agentIDs: ["a1"]) == .open("a1"))
    #expect(router.resolve(serverID: "server-a", serverURL: "http://server", agentIDs: ["a1"]) == nil)

    var foreign = NotificationTapRouter()
    foreign.queue(payload)
    #expect(foreign.resolve(serverID: "server-b", serverURL: "http://server", agentIDs: ["a1"]) == .differentServer)

    var bot = NotificationTapRouter()
    bot.queue(NotificationPayload(userInfo: [
      "type": "reply", "agentId": "a1", "agentName": "Atlas", "serverId": "server-a",
      "eventId": "evt-2", "origin": "bot",
    ]))
    #expect(bot.resolve(serverID: "server-a", serverURL: "http://server", agentIDs: ["a1"]) == nil)
  }
}
