import Foundation

enum Route: Hashable {
    case agent(String)
    case memory, skills, tasks, activity, integrations

    var title: String {
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

struct AgentDraft: Identifiable, Sendable {
    let id = UUID()
    var isNew: Bool
    var agentID: String
    var name = ""
    var description = ""
    var folder = "Personal"
    var enabled = true
    var provider = "melious"
    var model = ""
    var instructions = "You are a thoughtful, capable personal assistant."
    var avatar = "bot:" + newRequestID()
    var avatarChoices: [String] = []
    var thinking = "off"
    var temperature = ""
    var maxOutput = ""
    var toolsMemory = true
    var toolsDelegate = false
    var toolsSchedule = false
    var toolsCodemode = false
    var sharedMemory = false
    var delegates: Set<String> = []
    var mcpServers: Set<String> = []
    var skills: [Skill] = []
    var sharedSkills: Set<String> = []

    /// Offers new bots to pick from, keeping the current one first.
    mutating func shuffleAvatars() {
        avatarChoices = [agentAvatarSeed(Agent(id: agentID, avatar: avatar))]
        while avatarChoices.count < 7 { avatarChoices.append(newRequestID()) }
    }
}

struct MemoryDraft: Identifiable, Sendable {
    let id = UUID()
    var memoryID: String
    var content: String
    /// The owner is fixed when editing; nil means shared.
    var agentID: String?
}

struct SkillDraft: Identifiable, Sendable {
    let id = UUID()
    var skillID: String
    var agentID: String?
    var personal = false
    var name = ""
    var instructions = ""
}

struct TaskDraft: Identifiable, Sendable {
    let id = UUID()
    var scheduleID: String
    var agentID: String
    var name = ""
    var prompt = ""
    var repeats = false
    var cron = "0 9 * * *"
    var runDate = Calendar.current.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(3600)) ?? .now
    var timezone = TimeZone.current.identifier
    var enabled = true
}

struct MCPDraft: Identifiable, Sendable {
    let id = UUID()
    var serverID: String
    /// The bot a new server belongs to, or nil for a shared one; fixed once the server exists.
    var agentID: String?
    var name = ""
    var url = ""
    var token = ""
    var enabled = true
}
