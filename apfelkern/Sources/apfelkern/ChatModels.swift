import Foundation

/// Who started a turn: the owner, a scheduled task, or another bot.
public struct MessageOrigin: Codable, Hashable, Sendable {
  public var kind: String
  public var name: String?
  public var agentId: String?
  /// On an owner message sent through a message gateway: the gateway's ID.
  public var via: String?
  /// On an event automation's message: the event source that started it.
  public var source: String?

  public init(
    kind: String,
    name: String? = nil,
    agentId: String? = nil,
    via: String? = nil,
    source: String? = nil
  ) {
    self.kind = kind
    self.name = name
    self.agentId = agentId
    self.via = via
    self.source = source
  }
}

/// A persisted request or reply exchanged between two bots.
public struct BotCommunication: Codable, Hashable, Sendable {
  public var executionId: String
  public var fromAgentId: String
  public var fromName: String
  public var toAgentId: String
  public var toName: String
  public var status: String

  public init(
    executionId: String,
    fromAgentId: String,
    fromName: String,
    toAgentId: String,
    toName: String,
    status: String
  ) {
    self.executionId = executionId
    self.fromAgentId = fromAgentId
    self.fromName = fromName
    self.toAgentId = toAgentId
    self.toName = toName
    self.status = status
  }
}

/// The voice gateway call a `call-started` or `call-ended` event belongs to.
public struct CallEvent: Codable, Hashable, Sendable {
  public enum Direction: String, Codable, Hashable, Sendable {
    case inbound
    /// The bot called the owner.
    case outbound
  }

  public var callId: String
  public var direction: Direction
  /// Who an outside call phones; nil for a call with the owner.
  public var callee: String?

  public init(callId: String, direction: Direction, callee: String? = nil) {
    self.callId = callId
    self.direction = direction
    self.callee = callee
  }
}

/// Client-side delivery state for an optimistic owner message.
public enum MessageDeliveryState: String, Codable, Hashable, Sendable {
  case confirmed
  case sending
  case failed
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var entryId: String?
  public var role: String
  public var content: JSONValue?
  public var blocks: JSONValue?
  public var kind: String?
  public var replyTo: String?
  public var replyPreview: String?
  public var origin: MessageOrigin?
  public var communication: BotCommunication?
  public var jobQuestion: JobQuestionEvent?
  public var heldAction: HeldActionEvent?
  public var call: CallEvent?
  public var timestamp: Int64?
  public var createdAt: String?
  public var attachments: [AttachmentInfo]?
  public var toolName: String?
  public var toolCallId: String?
  public var isError: Bool?
  /// Tool result details for UIs, such as a `show` tool's `DisplayComponent`.
  public var toolDetails: JSONValue?
  /// The idempotency key echoed by the server for owner messages.
  public var requestId: String?
  /// In a group chat, the pages the sending bot searched or read in the turn that wrote the message.
  public var sources: [MessageSource]?
  public var deliveryState: MessageDeliveryState

  public init(
    id: String, entryId: String? = nil, role: String, content: JSONValue? = nil,
    blocks: JSONValue? = nil, kind: String? = nil,
    replyTo: String? = nil, replyPreview: String? = nil, origin: MessageOrigin? = nil,
    communication: BotCommunication? = nil, jobQuestion: JobQuestionEvent? = nil,
    heldAction: HeldActionEvent? = nil, call: CallEvent? = nil, timestamp: Int64? = nil,
    attachments: [AttachmentInfo]? = nil, toolName: String? = nil, toolCallId: String? = nil,
    isError: Bool? = nil,
    toolDetails: JSONValue? = nil, requestId: String? = nil, sources: [MessageSource]? = nil,
    deliveryState: MessageDeliveryState = .confirmed
  ) {
    self.id = id
    self.entryId = entryId
    self.role = role
    self.content = content
    self.blocks = blocks
    self.kind = kind
    self.replyTo = replyTo
    self.replyPreview = replyPreview
    self.origin = origin
    self.communication = communication
    self.jobQuestion = jobQuestion
    self.heldAction = heldAction
    self.call = call
    self.timestamp = timestamp
    self.attachments = attachments
    self.toolName = toolName
    self.toolCallId = toolCallId
    self.isError = isError
    self.toolDetails = toolDetails
    self.requestId = requestId
    self.sources = sources
    self.deliveryState = deliveryState
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    entryId = try container.decodeIfPresent(String.self, forKey: .entryId)
    role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
    content = try container.decodeIfPresent(JSONValue.self, forKey: .content)
    blocks = try container.decodeIfPresent(JSONValue.self, forKey: .blocks)
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
    replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
    replyPreview = try container.decodeIfPresent(String.self, forKey: .replyPreview)
    origin = try container.decodeIfPresent(MessageOrigin.self, forKey: .origin)
    communication = try container.decodeIfPresent(BotCommunication.self, forKey: .communication)
    jobQuestion = try container.decodeIfPresent(JobQuestionEvent.self, forKey: .jobQuestion)
    heldAction = try container.decodeIfPresent(HeldActionEvent.self, forKey: .heldAction)
    call = try container.decodeIfPresent(CallEvent.self, forKey: .call)
    timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
    createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    attachments = try container.decodeIfPresent([AttachmentInfo].self, forKey: .attachments)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
    isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
    toolDetails = try container.decodeIfPresent(JSONValue.self, forKey: .toolDetails)
    requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
    sources = try container.decodeIfPresent([MessageSource].self, forKey: .sources)
    deliveryState =
      try container.decodeIfPresent(MessageDeliveryState.self, forKey: .deliveryState) ?? .confirmed
  }

  public var text: String { contentText(content) }
}

/// A file a message carries, as the transcript lists it; its bytes are fetched by `id` separately.
public struct AttachmentInfo: Codable, Hashable, Sendable {
  /// The server's file ID; empty on an optimistic row the server has not confirmed yet.
  public var id: String
  public var name: String
  public var mimeType: String
  public var size: Int
  /// The file was deleted from its chat's library; only its ID remains.
  public var deleted: Bool

  /// Previews follow the MIME type; a deleted file has none.
  public var isImage: Bool { !deleted && mimeType.hasPrefix("image/") }

  public init(id: String = "", name: String, mimeType: String, size: Int, deleted: Bool = false) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.size = size
    self.deleted = deleted
  }

  public static func deleted(_ id: String) -> AttachmentInfo {
    AttachmentInfo(id: id, name: "", mimeType: "", size: 0, deleted: true)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
    size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
    deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
  }
}

public struct ChatSnapshot: Codable, Sendable {
  public var messages: [Message]?
  public var status: String?
  public var partial: String?
  public var error: String?
  public var agentId: String?
  public var hasMore: Bool?
  public var oldestEntryId: String?

  public var isRunning: Bool { status == "running" }

  public init(from decoder: Decoder) throws {
    let event = try Components.Schemas.EventChatSnapshot(from: decoder)
    let wire = try JSONDecoder().decode(
      Components.Schemas.ChatSnapshot.self, from: JSONEncoder().encode(event))
    try self.init(wire: wire)
  }

  public init(
    messages: [Message]? = nil,
    status: String? = nil,
    partial: String? = nil,
    error: String? = nil,
    agentId: String? = nil,
    hasMore: Bool? = nil,
    oldestEntryId: String? = nil
  ) {
    self.messages = messages
    self.status = status
    self.partial = partial
    self.error = error
    self.agentId = agentId
    self.hasMore = hasMore
    self.oldestEntryId = oldestEntryId
  }
}

public struct ChatHistoryResponse: Codable, Sendable {
  public var messages: [Message]?
  public var hasMore: Bool?
  public var oldestEntryId: String?

  public init(
    messages: [Message]? = nil,
    hasMore: Bool? = nil,
    oldestEntryId: String? = nil
  ) {
    self.messages = messages
    self.hasMore = hasMore
    self.oldestEntryId = oldestEntryId
  }
}
