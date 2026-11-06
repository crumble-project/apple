import Foundation

public struct ActivityFeedResponse: Sendable {
  public var activities: [ActivityEntry]
  public var hasMore: Bool
  /// Reads the next page. A page can run short while there is more.
  public var nextCursor: String?

  public init(activities: [ActivityEntry], hasMore: Bool, nextCursor: String? = nil) {
    self.activities = activities
    self.hasMore = hasMore
    self.nextCursor = nextCursor
  }
}

/// What the Activity page can narrow to.
public enum ActivityKind: String, CaseIterable, Identifiable, Sendable {
  case toolCall = "tool-call"
  case toolResult = "tool-result"
  case mcpCall = "mcp-call"
  case botMessage = "bot-message"
  case change

  public var id: Self { self }

  public var label: String {
    switch self {
    case .toolCall: "Tool calls"
    case .toolResult: "Tool results"
    case .mcpCall: "MCP calls"
    case .botMessage: "Bot messages"
    case .change: "Changes"
    }
  }

  public var symbol: String {
    switch self {
    case .toolCall: "wrench.and.screwdriver"
    case .toolResult: "arrow.turn.down.right"
    case .mcpCall: "powerplug"
    case .botMessage: "bubble.left.and.bubble.right"
    case .change: "clock.arrow.circlepath"
    }
  }
}

public struct ActivityEntry: Identifiable, Hashable, Sendable {
  public var id: String
  /// Nil for a change to the shared library.
  public var agentId: String?
  public var agentName: String?
  public var entryId: String?
  public var timestamp: Int64?
  public var kind: String
  public var details: [String: JSONValue]
  /// Set for a skill or memory change, whose `kind` is `change` and `details` are empty.
  public var change: LearnedChange?

  public init(id: String, agentId: String?, agentName: String?, entryId: String?,
              timestamp: Int64? = nil, kind: String, details: [String: JSONValue],
              change: LearnedChange? = nil) {
    self.id = id
    self.agentId = agentId
    self.agentName = agentName
    self.entryId = entryId
    self.timestamp = timestamp
    self.kind = kind
    self.details = details
    self.change = change
  }

  public var date: Date? { timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
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
  /// Set for a bot's answer in a group chat; open the group instead of the bot chat.
  public var groupId: String?
  public var groupName: String?
  /// Set for a bot's answer to a job's report (origin `coding` or `desktop`): the job's name.
  public var jobName: String?
  /// Set when the reply waits for the owner's answer: `approval`, `credential`, or `login`.
  public var waitingFor: String?

  public init(eventId: String? = nil, serverId: String? = nil, createdAt: String? = nil,
              type: String, agentId: String, agentName: String, entryId: String? = nil,
              origin: String? = nil, preview: String? = nil, lastMessage: String? = nil,
              groupId: String? = nil, groupName: String? = nil, jobName: String? = nil,
              waitingFor: String? = nil) {
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
    self.groupId = groupId
    self.groupName = groupName
    self.jobName = jobName
    self.waitingFor = waitingFor
  }

  public init(from decoder: Decoder) throws {
    switch try Components.Schemas.EventActivity(from: decoder) {
    case .case1(let wire):
      self.init(eventId: wire.eventId, serverId: wire.serverId, createdAt: wire.createdAt,
                type: wire._type.rawValue, agentId: wire.agentId, agentName: wire.agentName,
                entryId: wire.entryId, origin: wire.origin, preview: wire.preview,
                groupId: wire.groupId, groupName: wire.groupName, jobName: wire.jobName,
                waitingFor: wire.waitingFor?.rawValue)
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
        eventId: eventId, groupId: groupId, groupName: groupName, jobName: jobName, origin: origin, preview: preview,
        serverId: serverId, _type: .reply,
        waitingFor: waitingFor.flatMap(Components.Schemas.EventActivity.Case1Payload.WaitingForPayload.init(rawValue:))
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

/// What a reply notification asks of the owner, which decides its sound, as the web's notices do.
public enum NoticeKind: Sendable {
  case reply, approval, credential

  public init(_ event: ActivityEvent) {
    switch event.waitingFor {
    case nil: self = .reply
    case "credential", "login": self = .credential
    default: self = .approval
    }
  }

  /// The sound file each app bundles; a plain reply keeps the system sound.
  public var soundFile: String? {
    switch self {
    case .reply: nil
    case .approval: "notice-approval.wav"
    case .credential: "notice-credential.wav"
    }
  }
}
