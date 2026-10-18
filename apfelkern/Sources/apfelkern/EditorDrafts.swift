import Foundation

public enum Route: Hashable {
  case agent(String)
  case memory, skills, tasks, activity, integrations

  public var title: String {
    switch self {
    case .agent: "Chat"
    case .memory: "Memory"
    case .skills: "Skills"
    case .tasks: "Tasks"
    case .activity: "Activity"
    case .integrations: "Integrations"
    }
  }
}

public struct AgentDraft: Identifiable, Sendable {
  public let id = UUID()
  public var isNew: Bool
  public var agentID: String
  public var name = ""
  public var description = ""
  public var folder = "Personal"
  public var enabled = true
  public var provider = "melious"
  public var model = ""
  public var instructions = "You are a thoughtful, capable personal assistant."
  public var avatar = "bot:" + newRequestID()
  public var avatarChoices: [String] = []
  public var thinking = "off"
  public var temperature = ""
  public var maxOutput = ""
  public var toolsMemory = true
  public var toolsDelegate = false
  public var toolsSchedule = false
  public var toolsCodemode = false
  public var sharedMemory = false
  public var delegates: Set<String> = []
  public var mcpServers: Set<String> = []
  public var skills: [Skill] = []
  public var sharedSkills: Set<String> = []

  /// Offers new bots to pick from, keeping the current one first.
  public mutating func shuffleAvatars() {
    avatarChoices = [agentAvatarSeed(Agent(id: agentID, avatar: avatar))]
    while avatarChoices.count < 7 { avatarChoices.append(newRequestID()) }
  }

  public init(
    isNew: Bool,
    agentID: String,
    name: String = "",
    description: String = "",
    folder: String = "Personal",
    enabled: Bool = true,
    provider: String = "melious",
    model: String = "",
    instructions: String = "You are a thoughtful, capable personal assistant.",
    avatar: String = "bot:" + newRequestID(),
    avatarChoices: [String] = [],
    thinking: String = "off",
    temperature: String = "",
    maxOutput: String = "",
    toolsMemory: Bool = true,
    toolsDelegate: Bool = false,
    toolsSchedule: Bool = false,
    toolsCodemode: Bool = false,
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
    self.folder = folder
    self.enabled = enabled
    self.provider = provider
    self.model = model
    self.instructions = instructions
    self.avatar = avatar
    self.avatarChoices = avatarChoices
    self.thinking = thinking
    self.temperature = temperature
    self.maxOutput = maxOutput
    self.toolsMemory = toolsMemory
    self.toolsDelegate = toolsDelegate
    self.toolsSchedule = toolsSchedule
    self.toolsCodemode = toolsCodemode
    self.sharedMemory = sharedMemory
    self.delegates = delegates
    self.mcpServers = mcpServers
    self.skills = skills
    self.sharedSkills = sharedSkills
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

public struct TaskDraft: Identifiable, Sendable {
  public let id = UUID()
  public var scheduleID: String
  public var agentID: String
  public var name = ""
  public var prompt = ""
  public var repeats = false
  public var cron = "0 9 * * *"
  public var runDate =
    Calendar.current.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(3600)) ?? .now
  public var timezone = TimeZone.current.identifier
  public var enabled = true

  public init(
    scheduleID: String,
    agentID: String,
    name: String = "",
    prompt: String = "",
    repeats: Bool = false,
    cron: String = "0 9 * * *",
    runDate: Date = Calendar.current.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(3600)) ?? .now,
    timezone: String = TimeZone.current.identifier,
    enabled: Bool = true
  ) {
    self.scheduleID = scheduleID
    self.agentID = agentID
    self.name = name
    self.prompt = prompt
    self.repeats = repeats
    self.cron = cron
    self.runDate = runDate
    self.timezone = timezone
    self.enabled = enabled
  }
}

public struct MCPDraft: Identifiable, Sendable {
  public let id = UUID()
  public var serverID: String
  /// The bot a new server belongs to, or nil for a shared one; fixed once the server exists.
  public var agentID: String?
  public var name = ""
  public var url = ""
  public var token = ""
  public var enabled = true

  public init(
    serverID: String,
    agentID: String? = nil,
    name: String = "",
    url: String = "",
    token: String = "",
    enabled: Bool = true
  ) {
    self.serverID = serverID
    self.agentID = agentID
    self.name = name
    self.url = url
    self.token = token
    self.enabled = enabled
  }
}
