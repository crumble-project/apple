import Foundation

public struct PushStatus: Equatable, Sendable {
  public var serverId: String
  public var transports: [String: Bool]

  public init(serverId: String, transports: [String: Bool]) {
    self.serverId = serverId
    self.transports = transports
  }
}

public typealias PushRegistration = Components.Schemas.PushDeviceRegistration

public struct PushDevice: Hashable, Sendable {
  public var platform: String
  public var transport: String
  public var token: String
  public var environment: String
  public var bundleId: String
  public var enabled: Bool

  public init(platform: String, transport: String, token: String, environment: String,
              bundleId: String, enabled: Bool = true) {
    self.platform = platform
    self.transport = transport
    self.token = token
    self.environment = environment
    self.bundleId = bundleId
    self.enabled = enabled
  }
}

extension APIClient {
  public func activityFeed() async throws -> ActivityFeedResponse {
    try await invoke {
      let wire = try await $0.getActivityFeed(.init()).ok.body.json
      return ActivityFeedResponse(activities: try wire.activities.map { entry in
        if let change = entry.value2 {
          return ActivityEntry(
            id: change.id, agentId: change.agentId, agentName: change.agentName, entryId: nil,
            timestamp: Int64(change.timestamp), kind: change.kind.rawValue, details: [:],
            change: try LearnedChange(wire: change.change))
        }
        let operational = try required(entry.value1)
        return ActivityEntry(
          id: operational.id, agentId: operational.agentId, agentName: operational.agentName,
          entryId: operational.entryId, timestamp: operational.timestamp.flatMap(Int64.init(exactly:)),
          kind: operational.kind.rawValue,
          details: try operational.details.additionalProperties.mapValues { try JSONValue(wire: $0) })
      }, hasMore: wire.hasMore)
    }
  }

  public func pushStatus() async throws -> PushStatus {
    try await invoke {
      let wire = try await $0.getPushStatus(.init()).ok.body.json
      return PushStatus(serverId: wire.serverId, transports: ["apns": wire.transports.apns, "fcm": wire.transports.fcm])
    }
  }

  public func registerPush(_ installationID: String, device: PushDevice) async throws -> PushRegistration {
    typealias Body = Operations.PutPushDevice.Input.Body.JsonPayload
    guard let platform = Body.PlatformPayload(rawValue: device.platform),
          let transport = Body.TransportPayload(rawValue: device.transport),
          let environment = Body.EnvironmentPayload(rawValue: device.environment) else {
      throw EncodingError.invalidValue(device, .init(
        codingPath: [], debugDescription: "Invalid push device configuration"))
    }
    return try await invoke {
      try await $0.putPushDevice(.init(path: .init(installationId: installationID), body: .json(.init(
        bundleId: device.bundleId, enabled: device.enabled, environment: environment,
        platform: platform, token: device.token, transport: transport)))).ok.body.json
    }
  }

  public func unregisterPush(_ installationID: String) async throws {
    try await invoke { _ = try await $0.deletePushDevice(.init(path: .init(installationId: installationID))).noContent }
  }

  public func pushPresence(_ installationID: String, active: Bool, agentId: String?, timeout: TimeInterval = 20)
    async throws {
    try await invoke(timeout: timeout, nullFields: agentId == nil ? ["agentId"] : []) {
      _ = try await $0.putPushPresence(.init(path: .init(installationId: installationID),
        body: .json(.init(active: active, agentId: agentId)))).noContent
    }
  }
}
