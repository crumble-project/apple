import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  private func pushResponse(
    _ request: URLRequest, installationID: String, serverID: String,
    remoteDelivery: Bool?, deletionStatus: Int = 204
  ) -> (Int, String) {
    switch (request.httpMethod, request.url?.path) {
    case ("GET", "/v1/push"):
      (200, #"{"serverId":"\#(serverID)","transports":{"apns":true,"fcm":false}}"#)
    case ("PUT", "/v1/push/devices/\(installationID)"):
      remoteDelivery.map { (200, #"{"serverId":"\#(serverID)","remoteDelivery":\#($0)}"#) } ?? (404, "")
    case ("PUT", "/v1/push/devices/\(installationID)/presence"):
      remoteDelivery == nil ? (404, "") : (204, "")
    case ("DELETE", "/v1/push/devices/\(installationID)"):
      (deletionStatus, deletionStatus == 503 ? "busy" : "")
    default: (404, "")
    }
  }

  @MainActor @Test func failedOldServerCleanupBlocksNewRegistrationUntilRetry() async throws {
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
    let oldStub = StubProtocol.client(token: "old") { request in
      pushResponse(
        request, installationID: controller.installationID,
        serverID: "old", remoteDelivery: true, deletionStatus: 404)
    }
    let old = APIClient(baseURL: "http://old.test", token: "old", session: oldStub.session)
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(old)
    await controller.waitForSync()

    let newer = APIClient(baseURL: "http://new.test", token: "new", session: old.session)
    StubProtocol.handler = { request in
      pushResponse(
        request, installationID: controller.installationID,
        serverID: "new", remoteDelivery: false, deletionStatus: 503)
    }
    controller.setConnection(newer)
    await controller.waitForSync()
    #expect(!StubProtocol.requests.dropFirst(3).contains { $0.httpMethod == "PUT" && $0.url?.host == "new.test" })
    #expect(controller.status.contains("Previous server removal is pending"))
    #expect(!controller.remoteDelivery)

    StubProtocol.handler = { request in
      pushResponse(
        request, installationID: controller.installationID,
        serverID: "new", remoteDelivery: false)
    }
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
    #expect(StubProtocol.requests.contains { $0.httpMethod == "PUT" && $0.url?.host == "new.test" })
    #expect(!controller.remoteDelivery)
  }

  @MainActor @Test func failedCleanupForSameServerPreservesRemoteUntilRetry() async throws {
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
    let stub = StubProtocol.client(token: "old") { request in
      pushResponse(
        request, installationID: controller.installationID,
        serverID: "same", remoteDelivery: true, deletionStatus: 404)
    }
    let old = APIClient(baseURL: "http://same.test", token: "old", session: stub.session)
    controller.setAuthorized(true)
    controller.receivedToken(Data([1]))
    controller.setConnection(old)
    await controller.waitForSync()

    let newer = APIClient(baseURL: "http://same.test", token: "new", session: old.session)
    StubProtocol.handler = { request in
      pushResponse(
        request, installationID: controller.installationID,
        serverID: "same", remoteDelivery: nil, deletionStatus: 503)
    }
    controller.setConnection(newer)
    await controller.waitForSync()
    #expect(controller.remoteDelivery)
    #expect(controller.status.contains("Previous server removal is pending"))

    StubProtocol.handler = { request in
      pushResponse(
        request, installationID: controller.installationID,
        serverID: "same", remoteDelivery: false)
    }
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
    #expect(!controller.remoteDelivery)
  }

  @MainActor @Test func installationIDPersistsAcrossControllerRestart() async throws {
    let defaults = try pushDefaults()
    let first = PushController(defaults: defaults, persistCredentials: false)
    let second = PushController(defaults: defaults, persistCredentials: false)
    #expect(!first.installationID.isEmpty)
    #expect(second.installationID == first.installationID)
  }

  @MainActor @Test func disablingPushUnregistersExistingDevice() async throws {
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
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
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
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
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
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
      "eventId": "evt-1", "origin": "user", "preview": "Reply",
      "createdAt": ContractFixtures.timestamp, "entryId": NSNull()
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
      "eventId": "evt-1", "origin": "user", "preview": "Reply",
      "createdAt": ContractFixtures.timestamp, "entryId": NSNull()
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
      "eventId": "evt-2", "origin": "bot", "preview": "Reply",
      "createdAt": ContractFixtures.timestamp, "entryId": NSNull()
    ]))
    #expect(bot.resolve(serverID: "server-a", serverURL: "http://server", agentIDs: ["a1"]) == nil)
  }
}
