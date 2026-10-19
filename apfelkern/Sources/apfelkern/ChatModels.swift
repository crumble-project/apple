import Foundation

/// Who started a turn: the owner, a scheduled task, or another bot.
public struct MessageOrigin: Codable, Hashable, Sendable {
  public var kind: String
  public var name: String?
  public var agentId: String?

  public init(
    kind: String,
    name: String? = nil,
    agentId: String? = nil
  ) {
    self.kind = kind
    self.name = name
    self.agentId = agentId
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
  public var deliveryState: MessageDeliveryState

  public init(
    id: String, entryId: String? = nil, role: String, content: JSONValue? = nil,
    blocks: JSONValue? = nil, kind: String? = nil,
    replyTo: String? = nil, replyPreview: String? = nil, origin: MessageOrigin? = nil,
    communication: BotCommunication? = nil, timestamp: Int64? = nil,
    attachments: [AttachmentInfo]? = nil, toolName: String? = nil, toolCallId: String? = nil,
    isError: Bool? = nil,
    toolDetails: JSONValue? = nil, requestId: String? = nil,
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
    self.timestamp = timestamp
    self.attachments = attachments
    self.toolName = toolName
    self.toolCallId = toolCallId
    self.isError = isError
    self.toolDetails = toolDetails
    self.requestId = requestId
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
    timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
    createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    attachments = try container.decodeIfPresent([AttachmentInfo].self, forKey: .attachments)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
    isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
    toolDetails = try container.decodeIfPresent(JSONValue.self, forKey: .toolDetails)
    requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
    deliveryState =
      try container.decodeIfPresent(MessageDeliveryState.self, forKey: .deliveryState) ?? .confirmed
  }

  public var text: String { contentText(content) }
}

/// A file a sent message carries, as the transcript lists it; image bytes are fetched separately.
public struct AttachmentInfo: Codable, Hashable, Sendable {
  public var name: String
  public var mimeType: String
  public var size: Int
  public var kind: String

  public var isImage: Bool { kind == "image" }

  public init(
    name: String,
    mimeType: String,
    size: Int,
    kind: String
  ) {
    self.name = name
    self.mimeType = mimeType
    self.size = size
    self.kind = kind
  }
}

/// A file on its way to the server, in the shape the messages endpoint takes.
public struct OutgoingAttachment: Encodable, Hashable, Sendable {
  public var name: String
  public var mimeType: String
  public var data: String

  public init(
    name: String,
    mimeType: String,
    data: String
  ) {
    self.name = name
    self.mimeType = mimeType
    self.data = data
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
