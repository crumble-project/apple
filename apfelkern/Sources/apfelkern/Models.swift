import Foundation

/// Any JSON value: message content and blocks arrive in several shapes, and patches need explicit nulls.
public enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
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

  public func encode(to encoder: Encoder) throws {
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

  public init<T: Encodable>(encoding value: T) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public var prettyPrinted: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}

public struct Agent: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var instructions: String?
  public var avatar: String?
  public var enabled: Bool
  public var provider: String?
  public var model: String?
  public var tools: [String]?
  public var delegates: [String]?
  public var skills: [Skill]?
  public var sharedSkills: [String]?
  public var sharedMemory: Bool?
  public var mcpServers: [String]?
  public var inference: Inference?
  /// The model for this bot's desktop jobs; nil, they use the bot's own model.
  public var desktopModel: DesktopModel?
  public var lastMessage: String?

  public init(
    id: String = "", name: String = "", description: String? = nil, instructions: String? = nil,
    avatar: String? = nil,
    enabled: Bool = true, provider: String? = nil, model: String? = nil, tools: [String]? = nil,
    delegates: [String]? = nil, skills: [Skill]? = nil, sharedSkills: [String]? = nil,
    sharedMemory: Bool? = nil,
    mcpServers: [String]? = nil, inference: Inference? = nil, desktopModel: DesktopModel? = nil,
    lastMessage: String? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.instructions = instructions
    self.avatar = avatar
    self.enabled = enabled
    self.provider = provider
    self.model = model
    self.tools = tools
    self.delegates = delegates
    self.skills = skills
    self.sharedSkills = sharedSkills
    self.sharedMemory = sharedMemory
    self.mcpServers = mcpServers
    self.inference = inference
    self.desktopModel = desktopModel
    self.lastMessage = lastMessage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    description = try container.decodeIfPresent(String.self, forKey: .description)
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
    avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    tools = try container.decodeIfPresent([String].self, forKey: .tools)
    delegates = try container.decodeIfPresent([String].self, forKey: .delegates)
    skills = try container.decodeIfPresent([Skill].self, forKey: .skills)
    sharedSkills = try container.decodeIfPresent([String].self, forKey: .sharedSkills)
    sharedMemory = try container.decodeIfPresent(Bool.self, forKey: .sharedMemory)
    mcpServers = try container.decodeIfPresent([String].self, forKey: .mcpServers)
    inference = try container.decodeIfPresent(Inference.self, forKey: .inference)
    desktopModel = try container.decodeIfPresent(DesktopModel.self, forKey: .desktopModel)
    lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
  }
}

/// A provider's model, chosen for a bot's desktop jobs.
public struct DesktopModel: Codable, Hashable, Sendable {
  public var provider: String
  public var model: String

  public init(provider: String, model: String) {
    self.provider = provider
    self.model = model
  }
}

public struct Inference: Codable, Hashable, Sendable {
  public var thinkingLevel: String
  public var temperature: Double?
  public var maxOutputTokens: Int?

  public init(
    thinkingLevel: String,
    temperature: Double? = nil,
    maxOutputTokens: Int? = nil
  ) {
    self.thinkingLevel = thinkingLevel
    self.temperature = temperature
    self.maxOutputTokens = maxOutputTokens
  }
}

public struct ModelSummary: Codable, Hashable, Sendable {
  public var provider: String
  public var id: String
  public var name: String?
  public var contextWindow: Int?
  public var reasoning: Bool?

  public init(
    provider: String,
    id: String,
    name: String? = nil,
    contextWindow: Int? = nil,
    reasoning: Bool? = nil
  ) {
    self.provider = provider
    self.id = id
    self.name = name
    self.contextWindow = contextWindow
    self.reasoning = reasoning
  }
}

public struct Skill: Codable, Hashable, Sendable, Identifiable {
  public var id = UUID()
  public var name: String
  public var instructions: String

  enum CodingKeys: String, CodingKey { case name, instructions }

  public init(name: String = "", instructions: String = "") {
    self.name = name
    self.instructions = instructions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
  }
}

/// Where a memory was saved: the owner's bot chat, the owner directly, a scheduled task, another bot, or a group chat.
public struct MemorySource: Codable, Hashable, Sendable {
  public var kind: String
  /// The task, bot, or group chat, as named when the memory was saved.
  public var name: String?
  public var scheduleId: String?
  public var agentId: String?
  public var groupId: String?

  public init(
    kind: String, name: String? = nil, scheduleId: String? = nil, agentId: String? = nil,
    groupId: String? = nil
  ) {
    self.kind = kind
    self.name = name
    self.scheduleId = scheduleId
    self.agentId = agentId
    self.groupId = groupId
  }
}

public struct Memory: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var content: String
  public var createdAt: String?
  /// Nil for memories saved before sources were recorded.
  public var source: MemorySource?

  public init(
    id: String,
    content: String,
    createdAt: String? = nil,
    source: MemorySource? = nil
  ) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
    self.source = source
  }
}

/// A shared skill: bundled defaults apply to every bot; library entries are opt-in.
public struct SharedSkill: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var instructions: String
  public var source: String?
  public var path: String?

  public var isDefault: Bool { source == "bundled" }

  public init(
    id: String,
    name: String,
    instructions: String,
    source: String? = nil,
    path: String? = nil
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.source = source
    self.path = path
  }
}

public struct Schedule: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var agentId: String
  public var name: String
  public var cron: String?
  public var prompt: String
  public var timezone: String?
  public var runAt: String?
  public var enabled: Bool
  /// The bot that saved this task. Nil when the owner saved it.
  public var createdByAgentId: String?

  public init(
    id: String,
    agentId: String,
    name: String,
    cron: String? = nil,
    prompt: String,
    timezone: String? = nil,
    runAt: String? = nil,
    enabled: Bool,
    createdByAgentId: String? = nil
  ) {
    self.id = id
    self.agentId = agentId
    self.name = name
    self.cron = cron
    self.prompt = prompt
    self.timezone = timezone
    self.runAt = runAt
    self.enabled = enabled
    self.createdByAgentId = createdByAgentId
  }
}

public struct Execution: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var agentId: String?
  public var conversationId: String?
  public var status: String?
  public var prompt: String?
  public var error: String?
  public var createdAt: String?
  public var updatedAt: String?

  public init(
    id: String,
    agentId: String? = nil,
    conversationId: String? = nil,
    status: String? = nil,
    prompt: String? = nil,
    error: String? = nil,
    createdAt: String? = nil,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.agentId = agentId
    self.conversationId = conversationId
    self.status = status
    self.prompt = prompt
    self.error = error
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MCPServer: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var url: String
  public var enabled: Bool
  /// The bot the server belongs to, or nil when every bot may use it.
  public var agentId: String?
  public var authenticated: Bool?
  /// How the server signs in: "oauth", "token", or "none".
  public var auth: String?

  public init(
    id: String,
    name: String,
    url: String,
    enabled: Bool,
    agentId: String? = nil,
    authenticated: Bool? = nil,
    auth: String? = nil
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.enabled = enabled
    self.agentId = agentId
    self.authenticated = authenticated
    self.auth = auth
  }
}

/// The start of an OAuth sign-in: a URL to open, or `authorized` when saved tokens still work.
public struct OAuthStart: Decodable, Sendable {
  public var authorizationUrl: String?
  public var authorized: Bool?

  public init(
    authorizationUrl: String? = nil,
    authorized: Bool? = nil
  ) {
    self.authorizationUrl = authorizationUrl
    self.authorized = authorized
  }
}

/// Reads the visible text of message content: a string, text parts, or a text object.
public func contentText(_ value: JSONValue?) -> String {
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
