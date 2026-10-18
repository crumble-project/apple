import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  func pushDefaults() throws -> UserDefaults {
    let suite = "Crumble.PushNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  func pushDeviceBody(_ request: URLRequest) throws -> PushDevice {
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
      "DELETE /v1/push/devices/install-1"
    ])
    let registrationRequest = StubProtocol.requests[1]
    #expect(registrationRequest.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")
    #expect(try pushDeviceBody(registrationRequest) == PushDevice(
      token: "aabb", environment: "development", bundleId: "dev.crumble"))
    let presence = try #require(StubProtocol.requests[2].httpBody)
    #expect(try #require(String(data: presence, encoding: .utf8)).contains(#""agentId":"a1""#))
    let inactivePresence = try #require(StubProtocol.requests[3].httpBody)
    #expect(try #require(String(data: inactivePresence, encoding: .utf8)).contains(#""agentId":null"#))
  }

  @MainActor @Test func receivedTokenEncodesBytesAsLowercaseHex() async throws {
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
    controller.receivedToken(Data([0x00, 0x0a, 0xab, 0xff]))
    await controller.waitForSync()
    #expect(controller.deviceToken == "000aabff")
  }

  @MainActor @Test func registrationIncludesTokenAndRemoteDelivery() async throws {
    let defaults = try pushDefaults()
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
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
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
    controller.receivedToken(Data([0x01]))
    controller.setConnection(client)
    await controller.waitForSync()
    controller.receivedToken(Data([0x02, 0xa0]))
    await controller.waitForSync()

    let registrations = StubProtocol.requests.filter {
      $0.httpMethod == "PUT" && $0.url?.path.hasSuffix(controller.installationID) == true
    }
    #expect(registrations.count == 2)
    #expect(try pushDeviceBody(registrations[0]).token == "01")
    #expect(try pushDeviceBody(registrations[1]).token == "02a0")
    controller.setPresence(active: false, agentID: nil)
    await controller.waitForSync()
  }

  @MainActor @Test func mismatchedRegistrationIdentityDisablesRemoteDelivery() async throws {
    let controller = PushController(defaults: try pushDefaults(), persistCredentials: false)
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
}
