import Foundation

public struct ActivityFeedResponse: Sendable {
  public var activities: [ActivityEntry]
  public var hasMore: Bool

  public init(activities: [ActivityEntry], hasMore: Bool) {
    self.activities = activities
    self.hasMore = hasMore
  }
}

public struct ActivityEntry: Identifiable, Hashable, Sendable {
  public var id: String
  public var agentId: String
  public var agentName: String
  public var entryId: String
  public var timestamp: Int64?
  public var kind: String
  public var details: [String: JSONValue]

  public init(id: String, agentId: String, agentName: String, entryId: String,
              timestamp: Int64? = nil, kind: String, details: [String: JSONValue]) {
    self.id = id
    self.agentId = agentId
    self.agentName = agentName
    self.entryId = entryId
    self.timestamp = timestamp
    self.kind = kind
    self.details = details
  }
}

public struct ActivityEvent: Codable, Hashable, Sendable {
  public var eventId: String?
  public var serverId: String?
  public var createdAt: String?
  public var type: String
  public var agentId: String
  public var agentName: String
  public var entryId: String?
  public var origin: String?
  public var preview: String?
  public var lastMessage: String?

  public init(eventId: String? = nil, serverId: String? = nil, createdAt: String? = nil,
              type: String, agentId: String, agentName: String, entryId: String? = nil,
              origin: String? = nil, preview: String? = nil, lastMessage: String? = nil) {
    self.eventId = eventId
    self.serverId = serverId
    self.createdAt = createdAt
    self.type = type
    self.agentId = agentId
    self.agentName = agentName
    self.entryId = entryId
    self.origin = origin
    self.preview = preview
    self.lastMessage = lastMessage
  }

  public init(from decoder: Decoder) throws {
    switch try Components.Schemas.EventActivity(from: decoder) {
    case .case1(let wire):
      self.init(eventId: wire.eventId, serverId: wire.serverId, createdAt: wire.createdAt,
                type: wire._type.rawValue, agentId: wire.agentId, agentName: wire.agentName,
                entryId: wire.entryId, origin: wire.origin, preview: wire.preview)
    case .case2(let wire):
      self.init(type: wire._type.rawValue, agentId: wire.agentId, agentName: wire.agentName,
                lastMessage: wire.lastMessage)
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch type {
    case "reply":
      guard let eventId, let serverId, let createdAt, let origin, let preview else {
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
          debugDescription: "A reply event requires eventId, serverId, createdAt, origin, and preview"))
      }
      try Components.Schemas.EventActivity.case1(.init(
        agentId: agentId, agentName: agentName, createdAt: createdAt, entryId: entryId,
        eventId: eventId, origin: origin, preview: preview, serverId: serverId, _type: .reply
      )).encode(to: encoder)
    case "chat-preview":
      guard let lastMessage else {
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
          debugDescription: "A chat-preview event requires lastMessage"))
      }
      try Components.Schemas.EventActivity.case2(.init(
        agentId: agentId, agentName: agentName, lastMessage: lastMessage, _type: .chatPreview
      )).encode(to: encoder)
    default:
      throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
        debugDescription: "Unknown activity event type"))
    }
  }
}
