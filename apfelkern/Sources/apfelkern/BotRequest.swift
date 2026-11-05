import Foundation

/// A bot's proposal for a new bot, waiting for the owner or decided.
public struct BotRequest: Identifiable, Hashable, Sendable {
  public enum Status: Hashable, Sendable {
    case pending
    case approved
    case declined
  }

  public static let toolName = "request_bot"

  public var id: String
  /// The bot that asked.
  public var agentID: String
  /// The proposed bot, with no ID until it exists.
  public var proposal: Agent
  public var reason: String
  public var status: Status
  public var createdAgentID: String?
  /// The proposal as the server holds it, for the fields `Agent` doesn't carry.
  private var savedProposal: [String: JSONValue]

  /// A `request_bot` result carries the request as it was saved. Whether it still waits is in the
  /// bot's requests.
  public init?(message: Message) {
    guard message.role == "toolResult", message.toolName == Self.toolName, message.isError != true,
      let details = message.toolDetails,
      let wire: Components.Schemas.BotRequest = try? details.decoded(),
      let request = try? Self(wire: wire)
    else { return nil }
    self = request
  }

  /// The tools and MCP servers the proposal grants, named as the owner knows them.
  public func capabilityNames(servers: [MCPServer]) -> [String] {
    (proposal.tools ?? []).map { Self.capabilityNames[$0] ?? $0 }
      + (proposal.mcpServers ?? []).map { id in servers.first { $0.id == id }?.name ?? id }
  }

  private static let capabilityNames = [
    "memory": "Memory", "web": "Web search", "delegate": "Message other bots", "coding": "Coding",
    DesktopJob.toolName: "Bot desktop", "create_bots": "Create bots", "schedule": "Schedule tasks",
    "codemode": "Code mode"
  ]

  /// The proposal with what the editor shows replaced by `bot`. Fields without an editor, such as
  /// the bot's review settings, stay as proposed.
  func proposal(editedTo bot: Agent) throws -> JSONValue {
    var edited = savedProposal
    edited["name"] = .string(bot.name)
    edited["description"] = .string(bot.description ?? "")
    edited["instructions"] = .string(bot.instructions ?? "")
    edited["avatar"] = try JSONValue(encoding: bot.avatar)
    edited["enabled"] = .bool(bot.enabled)
    edited["provider"] = bot.provider.map(JSONValue.string)
    edited["model"] = bot.model.map(JSONValue.string)
    edited["tools"] = try JSONValue(encoding: bot.tools ?? [])
    edited["skills"] = try JSONValue(encoding: bot.skills ?? [])
    edited["sharedMemory"] = bot.sharedMemory.map(JSONValue.bool)
    edited["mcpServers"] = try JSONValue(encoding: bot.mcpServers ?? [])
    edited["delegates"] = try JSONValue(encoding: bot.delegates ?? [])
    edited["inference"] = try bot.inference.map { try JSONValue(encoding: $0) }
    edited["desktopModel"] = try bot.desktopModel.map { try JSONValue(encoding: $0) }
    return .object(edited)
  }
}

extension BotRequest {
  init(wire: Components.Schemas.BotRequest) throws {
    guard case .object(var saved) = try JSONValue(encoding: wire.proposal) else {
      throw DecodingError.valueNotFound(
        [String: JSONValue].self, .init(codingPath: [], debugDescription: "Expected a proposal object"))
    }
    let avatar: BotAvatarDefinition = try saved["avatar"].map {
      BotAvatarDefinition(wire: try $0.decoded(), botID: wire.id)
    } ?? .default(for: wire.id)
    saved["avatar"] = try JSONValue(encoding: avatar)
    id = wire.id
    agentID = wire.agentId
    proposal = try JSONValue.object(saved).decoded()
    reason = wire.reason
    status = switch wire.status {
    case .pending: .pending
    case .approved: .approved
    case .declined: .declined
    }
    createdAgentID = wire.createdAgentId
    savedProposal = saved
  }
}

extension JSONValue {
  fileprivate func decoded<T: Decodable>() throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
  }
}
