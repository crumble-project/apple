import Foundation

public enum Route: Hashable {
  case agent(String)
  case group(String)
  case memory, skills, automations, activity, avatars, judgeModel, visionModel, integrations, coding, users
  case providers, passwordManagers, credentials, logins, webSearch, messageGateways, eventRelay

  public var title: String {
    switch self {
    case .agent: "Chat"
    case .group: "Group Chat"
    case .memory: "Memory"
    case .skills: "Skills"
    case .automations: "Automations"
    case .activity: "Activity"
    case .avatars: "Avatars"
    case .judgeModel: JudgeModelSettings.title
    case .visionModel: VisionModelSettings.title
    case .integrations: "Integrations"
    case .coding: "Coding"
    case .users: "Users"
    case .providers: "Providers"
    case .passwordManagers: "Password managers"
    case .credentials: BotSecretKind.credential.title
    case .logins: BotSecretKind.login.title
    case .webSearch: "Web search"
    case .messageGateways: "Message gateways"
    case .eventRelay: "Event relay"
    }
  }

  /// The kind a cross-bot page lists, if this is one.
  public var botSecretKind: BotSecretKind? {
    switch self {
    case .credentials: .credential
    case .logins: .login
    default: nil
    }
  }
}

public struct AgentDraft: Identifiable, Sendable {
  public let id = UUID()
  public var isNew: Bool
  public var agentID: String
  public var name = ""
  public var description = ""
  public var enabled = true
  public var provider = "melious"
  public var model = ""
  public var instructions = "You are a thoughtful, capable personal assistant."
  public var avatar = BotAvatarDefinition.default(for: newRequestID())
  public var thinking = "off"
  public var temperature = ""
  public var maxOutput = ""
  public var toolsMemory = true
  public var toolsWeb = true
  /// Nil uses the account default.
  public var webSearchProvider: WebSearchProvider?
  public var toolsDelegate = true
  public var toolsSchedule = true
  public var toolsCodemode = true
  public var toolsCoding = false
  public var toolsDesktop = false
  public var toolsCreateBots = false
  /// The desktop job model's provider and model; both empty means the bot's own model.
  public var desktopProvider = ""
  public var desktopModel = ""
  public var sharedMemory = false
  public var delegates: Set<String> = []
  public var mcpServers: Set<String> = []
  public var skills: [Skill] = []
  public var sharedSkills: Set<String> = []
  /// Saving this draft approves the request instead of creating or updating a bot.
  public var botRequest: BotRequest?

  public init(
    isNew: Bool,
    agentID: String,
    name: String = "",
    description: String = "",
    enabled: Bool = true,
    provider: String = "melious",
    model: String = "",
    instructions: String = "You are a thoughtful, capable personal assistant.",
    avatar: BotAvatarDefinition = .default(for: newRequestID()),
    thinking: String = "off",
    temperature: String = "",
    maxOutput: String = "",
    toolsMemory: Bool = true,
    toolsWeb: Bool = true,
    webSearchProvider: WebSearchProvider? = nil,
    toolsDelegate: Bool = true,
    toolsSchedule: Bool = true,
    toolsCodemode: Bool = true,
    toolsCoding: Bool = false,
    toolsDesktop: Bool = false,
    toolsCreateBots: Bool = false,
    desktopProvider: String = "",
    desktopModel: String = "",
    sharedMemory: Bool = false,
    delegates: Set<String> = [],
    mcpServers: Set<String> = [],
    skills: [Skill] = [],
    sharedSkills: Set<String> = []
  ) {
    self.isNew = isNew
    self.agentID = agentID
    self.name = name
    self.description = description
    self.enabled = enabled
    self.provider = provider
    self.model = model
    self.instructions = instructions
    self.avatar = avatar
    self.thinking = thinking
    self.temperature = temperature
    self.maxOutput = maxOutput
    self.toolsMemory = toolsMemory
    self.toolsWeb = toolsWeb
    self.webSearchProvider = webSearchProvider
    self.toolsDelegate = toolsDelegate
    self.toolsSchedule = toolsSchedule
    self.toolsCodemode = toolsCodemode
    self.toolsCoding = toolsCoding
    self.toolsDesktop = toolsDesktop
    self.toolsCreateBots = toolsCreateBots
    self.desktopProvider = desktopProvider
    self.desktopModel = desktopModel
    self.sharedMemory = sharedMemory
    self.delegates = delegates
    self.mcpServers = mcpServers
    self.skills = skills
    self.sharedSkills = sharedSkills
  }

  public init(agent: Agent) {
    self.init(isNew: false, agentID: agent.id)
    name = agent.name
    description = agent.description ?? ""
    instructions = agent.instructions ?? ""
    model = agent.model ?? ""
    provider = agent.provider ?? ""
    enabled = agent.enabled
    avatar = agent.avatar
    if let inference = agent.inference {
      thinking = inference.thinkingLevel
      temperature = inference.temperature.map { String($0) } ?? ""
      maxOutput = inference.maxOutputTokens.map { String($0) } ?? ""
    }
    let tools = agent.tools ?? []
    toolsMemory = tools.contains("memory")
    toolsWeb = tools.contains("web")
    webSearchProvider = agent.webSearchProvider
    toolsDelegate = tools.contains("delegate")
    toolsSchedule = tools.contains("schedule")
    toolsCodemode = tools.contains("codemode")
    toolsCoding = tools.contains("coding")
    toolsDesktop = tools.contains(DesktopJob.toolName)
    toolsCreateBots = tools.contains("create_bots")
    desktopProvider = agent.desktopModel?.provider ?? ""
    desktopModel = agent.desktopModel?.model ?? ""
    skills = agent.skills ?? []
    sharedSkills = Set(agent.sharedSkills ?? [])
    sharedMemory = agent.sharedMemory ?? false
    delegates = Set(agent.delegates ?? [])
    mcpServers = Set(agent.mcpServers ?? [])
  }

  /// The proposal, to edit before approving it.
  public init(botRequest: BotRequest) {
    self.init(agent: botRequest.proposal)
    isNew = true
    self.botRequest = botRequest
  }

  /// A proposal needs a name and a model to become a bot.
  public var canApprove: Bool {
    [name, provider, model].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// The bot's tools after saving: the toggles, plus the `stored` tools set elsewhere that have no toggle.
  public func tools(keeping stored: [String]) -> [String] {
    let toggles = [
      ("memory", toolsMemory), ("web", toolsWeb), ("delegate", toolsDelegate), ("schedule", toolsSchedule),
      ("codemode", toolsCodemode), ("coding", toolsCoding), (DesktopJob.toolName, toolsDesktop),
      ("create_bots", toolsCreateBots)
    ]
    let toggled = Set(toggles.map(\.0))
    return toggles.filter(\.1).map(\.0) + stored.filter { !toggled.contains($0) }
  }

  /// Both fields set picks a model for desktop jobs; otherwise they use the bot's own model.
  public var desktopModelChoice: DesktopModel? {
    let provider = desktopProvider.trimmingCharacters(in: .whitespaces)
    let model = desktopModel.trimmingCharacters(in: .whitespaces)
    return provider.isEmpty || model.isEmpty ? nil : DesktopModel(provider: provider, model: model)
  }
}

public struct MemoryDraft: Identifiable, Sendable {
  public let id = UUID()
  public var memoryID: String
  public var content: String
  /// The owner is fixed when editing; nil means shared.
  public var agentID: String?

  public init(
    memoryID: String,
    content: String,
    agentID: String? = nil
  ) {
    self.memoryID = memoryID
    self.content = content
    self.agentID = agentID
  }
}

public struct MCPDraft: Identifiable, Sendable {
  public let id = UUID()
  public var serverID: String
  /// The bot a new server belongs to, or nil for a shared one; fixed once the server exists.
  public var agentID: String?
  public var name = ""
  public var url = ""
  public var token = SecretSourceDraft()
  public var enabled = true
  /// The owner's OAuth app; empty lets the server register Crumble itself.
  public var clientID = ""
  public var clientSecret = SecretSourceDraft()
  private var hasSavedToken = false
  private var savedClientID: String?

  public init(
    serverID: String,
    agentID: String? = nil,
    name: String = "",
    url: String = "",
    enabled: Bool = true
  ) {
    self.serverID = serverID
    self.agentID = agentID
    self.name = name
    self.url = url
    self.enabled = enabled
  }

  public init(server: MCPServer) {
    self.init(
      serverID: server.id, agentID: server.agentId, name: server.name, url: server.url, enabled: server.enabled)
    token = SecretSourceDraft(saved: server.token)
    hasSavedToken = server.auth == "token"
    clientID = server.oauthClientId ?? ""
    clientSecret = SecretSourceDraft(saved: server.oauthClientSecret)
    savedClientID = server.oauthClientId
  }

  public var tokenPlaceholder: String { hasSavedToken ? "Replace the saved token" : "Optional" }

  public var tokenNote: String {
    "Sent as a bearer token. Leave it empty for servers that need no sign-in or use OAuth."
  }

  /// Whether a save sends a token: the saved reference isn't read again when other fields change.
  public var changesToken: Bool { token.changedInput != nil }

  public var hasClientID: Bool { !trimmedClientID.isEmpty }

  private var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

  public var clientSecretPlaceholder: String {
    clientSecret.saved?.configured == true ? "Replace the saved secret" : "Client secret, optional"
  }

  public var clientSecretNote: String {
    "Stored encrypted and never shown again. Changing the app signs the server out."
  }

  /// `callback` is the address this app's sign-in returns to, which the OAuth app has to list.
  public static func oauthAppNote(callback: String) -> String {
    "Only for servers whose sign-in can't register Crumble, such as GitHub's. Register an OAuth app there "
      + "with the callback URL \(callback) and enter its client ID and secret."
  }

  private var sendsClientSecret: SecretInput? { hasClientID ? clientSecret.changedInput : nil }

  /// The server signs out of a server whose OAuth app changes, so a save shouldn't look signed in.
  public var changesOAuthApp: Bool {
    trimmedClientID.nilIfEmpty != savedClientID || sendsClientSecret != nil
  }

  /// The server reads a new reference before it answers, so the outcome depends on a password manager.
  public var checksPasswordManager: Bool {
    if token.changesReference { return true }
    if case .reference? = sendsClientSecret { return true }
    return false
  }

  /// The fields a save sends, with `name` and `url` already trimmed. Clearing the client ID clears
  /// its secret too, because a secret means nothing without the app it belongs to.
  public func payload(name: String, url: String) -> [String: JSONValue] {
    var payload: [String: JSONValue] = [
      "name": .string(name), "url": .string(url), "enabled": .bool(enabled)
    ]
    if let input = token.changedInput { payload["token"] = input.json }
    if hasClientID {
      payload["oauthClientId"] = .string(trimmedClientID)
    } else if savedClientID != nil {
      payload["oauthClientId"] = .null
    }
    if let input = sendsClientSecret {
      payload["oauthClientSecret"] = input.json
    } else if !hasClientID, clientSecret.saved?.configured == true {
      payload["oauthClientSecret"] = .null
    }
    return payload
  }

  /// `server` as this draft will leave it, to show until the server answers. The secret stays out.
  public func applyingOAuthApp(to server: MCPServer) -> MCPServer {
    var server = server
    server.oauthClientId = trimmedClientID.nilIfEmpty
    server.oauthClientSecret = !hasClientID
      ? SecretStatus(configured: false)
      : SecretStatus(configured: sendsClientSecret != nil || clientSecret.saved?.configured == true)
    if changesOAuthApp, server.auth == "oauth" {
      server.authenticated = false
      server.auth = "none"
    }
    return server
  }
}
