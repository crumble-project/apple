import Foundation

/// Any JSON value: message content and blocks arrive in several shapes, and patches need explicit nulls.
enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  init<T: Encodable>(encoding value: T) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  var prettyPrinted: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}

struct Agent: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var description: String?
  var instructions: String?
  var avatar: String?
  var enabled: Bool
  var provider: String?
  var model: String?
  var folder: String?
  var tools: [String]?
  var delegates: [String]?
  var skills: [Skill]?
  var sharedSkills: [String]?
  var sharedMemory: Bool?
  var mcpServers: [String]?
  var inference: Inference?
  var lastMessage: String?

  init(
    id: String = "", name: String = "", description: String? = nil, instructions: String? = nil,
    avatar: String? = nil,
    enabled: Bool = true, provider: String? = nil, model: String? = nil, folder: String? = nil,
    tools: [String]? = nil,
    delegates: [String]? = nil, skills: [Skill]? = nil, sharedSkills: [String]? = nil,
    sharedMemory: Bool? = nil,
    mcpServers: [String]? = nil, inference: Inference? = nil, lastMessage: String? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.instructions = instructions
    self.avatar = avatar
    self.enabled = enabled
    self.provider = provider
    self.model = model
    self.folder = folder
    self.tools = tools
    self.delegates = delegates
    self.skills = skills
    self.sharedSkills = sharedSkills
    self.sharedMemory = sharedMemory
    self.mcpServers = mcpServers
    self.inference = inference
    self.lastMessage = lastMessage
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    description = try c.decodeIfPresent(String.self, forKey: .description)
    instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
    avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    provider = try c.decodeIfPresent(String.self, forKey: .provider)
    model = try c.decodeIfPresent(String.self, forKey: .model)
    folder = try c.decodeIfPresent(String.self, forKey: .folder)
    tools = try c.decodeIfPresent([String].self, forKey: .tools)
    delegates = try c.decodeIfPresent([String].self, forKey: .delegates)
    skills = try c.decodeIfPresent([Skill].self, forKey: .skills)
    sharedSkills = try c.decodeIfPresent([String].self, forKey: .sharedSkills)
    sharedMemory = try c.decodeIfPresent(Bool.self, forKey: .sharedMemory)
    mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers)
    inference = try c.decodeIfPresent(Inference.self, forKey: .inference)
    lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
  }
}

struct Inference: Codable, Hashable, Sendable {
  var thinkingLevel: String
  var temperature: Double?
  var maxOutputTokens: Int?
}

struct ModelSummary: Codable, Hashable, Sendable {
  var provider: String
  var id: String
  var name: String?
  var contextWindow: Int?
  var reasoning: Bool?
}

struct Skill: Codable, Hashable, Sendable, Identifiable {
  var id = UUID()
  var name: String
  var instructions: String

  enum CodingKeys: String, CodingKey { case name, instructions }

  init(name: String = "", instructions: String = "") {
    self.name = name
    self.instructions = instructions
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
  }
}

/// Who started a turn: the owner, a scheduled task, or another bot.
struct MessageOrigin: Codable, Hashable, Sendable {
  var kind: String
  var name: String?
  var agentId: String?
}

/// A persisted request or reply exchanged between two bots.
struct BotCommunication: Codable, Hashable, Sendable {
  var executionId: String
  var fromAgentId: String
  var fromName: String
  var toAgentId: String
  var toName: String
  var status: String
}

/// Client-side delivery state for an optimistic owner message.
enum MessageDeliveryState: String, Codable, Hashable, Sendable {
  case confirmed
  case sending
  case failed
}

struct Message: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var entryId: String?
  var role: String
  var content: JSONValue?
  var blocks: JSONValue?
  var kind: String?
  var replyTo: String?
  var replyPreview: String?
  var origin: MessageOrigin?
  var communication: BotCommunication?
  var timestamp: Int64?
  var createdAt: String?
  var attachments: [AttachmentInfo]?
  /// The idempotency key echoed by the server for owner messages.
  var requestId: String?
  var deliveryState: MessageDeliveryState

  init(
    id: String, entryId: String? = nil, role: String, content: JSONValue? = nil,
    blocks: JSONValue? = nil, kind: String? = nil,
    replyTo: String? = nil, replyPreview: String? = nil, origin: MessageOrigin? = nil,
    communication: BotCommunication? = nil, timestamp: Int64? = nil,
    attachments: [AttachmentInfo]? = nil, requestId: String? = nil,
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
    self.requestId = requestId
    self.deliveryState = deliveryState
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    entryId = try c.decodeIfPresent(String.self, forKey: .entryId)
    role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
    content = try c.decodeIfPresent(JSONValue.self, forKey: .content)
    blocks = try c.decodeIfPresent(JSONValue.self, forKey: .blocks)
    kind = try c.decodeIfPresent(String.self, forKey: .kind)
    replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
    replyPreview = try c.decodeIfPresent(String.self, forKey: .replyPreview)
    origin = try c.decodeIfPresent(MessageOrigin.self, forKey: .origin)
    communication = try c.decodeIfPresent(BotCommunication.self, forKey: .communication)
    timestamp = try c.decodeIfPresent(Int64.self, forKey: .timestamp)
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    attachments = try c.decodeIfPresent([AttachmentInfo].self, forKey: .attachments)
    requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    deliveryState =
      try c.decodeIfPresent(MessageDeliveryState.self, forKey: .deliveryState) ?? .confirmed
  }

  var text: String { contentText(content) }
}

/// A file a sent message carries, as the transcript lists it; image bytes are fetched separately.
struct AttachmentInfo: Codable, Hashable, Sendable {
  var name: String
  var mimeType: String
  var size: Int
  var kind: String

  var isImage: Bool { kind == "image" }
}

/// A file on its way to the server, in the shape the messages endpoint takes.
struct OutgoingAttachment: Encodable, Hashable, Sendable {
  var name: String
  var mimeType: String
  var data: String
}

struct ChatSnapshot: Codable, Sendable {
  var messages: [Message]?
  var status: String?
  var partial: String?
  var error: String?
  var agentId: String?
  var hasMore: Bool?
  var oldestEntryId: String?

  var isRunning: Bool { status == "running" }
}

struct ChatHistoryResponse: Codable, Sendable {
  var messages: [Message]?
  var hasMore: Bool?
  var oldestEntryId: String?
}

struct Memory: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var content: String
  var createdAt: String?
}

/// A shared skill: bundled defaults apply to every bot; library entries are opt-in.
struct SharedSkill: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var instructions: String
  var source: String?
  var path: String?

  var isDefault: Bool { source == "bundled" }
}

struct Schedule: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var agentId: String
  var name: String
  var cron: String?
  var prompt: String
  var timezone: String?
  var runAt: String?
  var enabled: Bool
  /// The bot that saved this task. Nil when the owner saved it.
  var createdByAgentId: String?
}

struct Execution: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var agentId: String?
  var conversationId: String?
  var status: String?
  var prompt: String?
  var error: String?
  var createdAt: String?
  var updatedAt: String?
}

struct ProviderStatus: Codable, Hashable, Sendable {
  var provider: String
  var name: String?
  var configured: Bool
}

struct MCPServer: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var url: String
  var enabled: Bool
  /// The bot the server belongs to, or nil when every bot may use it.
  var agentId: String?
  var authenticated: Bool?
  /// How the server signs in: "oauth", "token", or "none".
  var auth: String?
}

/// The start of an OAuth sign-in: a URL to open, or `authorized` when saved tokens still work.
struct OAuthStart: Decodable, Sendable {
  var authorizationUrl: String?
  var authorized: Bool?
}

/// Reads the visible text of message content: a string, text parts, or a text object.
func contentText(_ value: JSONValue?) -> String {
  switch value {
  case nil, .null?:
    return ""
  case .string(let text)?:
    return text
  case .array(let items)?:
    let parts = items.compactMap { $0["text"]?.stringValue }
    if !parts.isEmpty { return parts.joined() }
  case .object?:
    if let text = value?["text"]?.stringValue { return text }
  default:
    break
  }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}
