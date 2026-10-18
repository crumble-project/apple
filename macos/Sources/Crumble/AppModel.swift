import AppKit
import AuthenticationServices
import Foundation
import Observation
import SwiftUI

enum Route: Hashable {
    case agent(String)
    case memory, skills, tasks, activity, approvals, integrations

    var title: String {
        switch self {
        case .agent: "Chat"
        case .memory: "Memory"
        case .skills: "Skills"
        case .tasks: "Tasks"
        case .activity: "Activity"
        case .approvals: "Approvals"
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

/// The window's state and the actions that change it. Network work runs in tasks that report back
/// on the main actor; results from a replaced connection or a previous agent are dropped.
@MainActor @Observable
final class AppModel {
    var serverURL = "http://127.0.0.1:7337"
    var token = ""
    private(set) var client: APIClient?
    private var generation = 0

    var agents: [Agent] = []
    var route: Route?
    private(set) var selectedAgentID = ""
    private var selectionVersion = 0

    var snapshot: ChatSnapshot?
    var messages: [Message] = []
    var hasMore = false
    var oldestEntryID = ""
    var loadingOlder = false
    var expanded: Set<String> = []

    var draft = ""
    var attachments: [PendingAttachment] = []
    var replyTo: Message?
    var sending = false
    private var draftRequestID = ""
    private var failedDraft = ""
    private var failedReplyTo = ""
    private var failedAttachments: [UUID] = []
    /// Sent images, keyed by entry and attachment index; they never change once sent.
    private(set) var attachmentImages: [String: NSImage] = [:]

    private var activeRequests = 0
    var loading = false
    var errorText = ""
    var notice = ""
    var streamStatus = ""
    private var streamTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?

    var agentMemories: [String: [Memory]] = [:]
    private var memoryLoadVersion = 0
    var sharedMemories: [Memory] = []
    var sharedSkills: [SharedSkill] = []
    var schedules: [Schedule] = []
    var executions: [Execution] = []
    var approvals: [Approval] = []
    var mcpServers: [MCPServer] = []
    var providers: [ProviderStatus] = []
    var models: [ModelSummary] = []

    var agentDraft: AgentDraft?
    var memoryDraft: MemoryDraft?
    var taskDraft: TaskDraft?
    var mcpDraft: MCPDraft?
    var skillDraft: SkillDraft?
    /// The MCP server whose sign-in sheet is open.
    var signingIn: String?
    var confirmingDelete = false

    var provider = "melious"
    var providerKey = ""

    init(environment: [String: String] = ProcessInfo.processInfo.environment, loadKeychain: Bool = true) {
        if loadKeychain {
            if let saved = Keychain.read("server-url"), !saved.isEmpty { serverURL = saved }
            if let saved = Keychain.read("server-token") { token = saved }
        }
        if let url = environment["CRUMBLE_URL"]?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
            serverURL = url.trimmingTrailingSlashes
        }
        if let envToken = environment["CRUMBLE_TOKEN"], !envToken.isEmpty { token = envToken }
        client = APIClient(baseURL: serverURL, token: token)
    }

    init(client: APIClient) {
        self.client = client
    }

    var selectedAgent: Agent? { agents.first { $0.id == selectedAgentID } }

    func botState(_ agent: Agent) -> BotState {
        if !agent.enabled { return .sleeping }
        if agent.id == selectedAgentID, snapshot?.isRunning == true { return .working }
        return .idle
    }

    // MARK: Requests

    private func request(_ work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?) {
        guard let client else {
            errorText = "Connect to your server in Settings."
            return
        }
        let generation = generation
        activeRequests += 1
        loading = true
        errorText = ""
        Task {
            do {
                let apply = try await work(client)
                guard self.generation == generation else { return }
                finishRequest()
                apply?()
            } catch {
                guard self.generation == generation else { return }
                finishRequest()
                errorText = friendlyError(error)
            }
        }
    }

    private func finishRequest() {
        activeRequests = max(0, activeRequests - 1)
        loading = activeRequests > 0
    }

    func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = "" }
        }
    }

    // MARK: Agents and chat

    func refresh() {
        request { client in
            let agents = try await client.agents()
            return { [self] in
                self.agents = agents
                var chosen = selectedAgentID
                if !agents.contains(where: { $0.id == chosen }) { chosen = agents.first?.id ?? "" }
                if chosen.isEmpty {
                    cancelStream()
                    selectedAgentID = ""
                    snapshot = nil
                    messages = []
                } else {
                    selectAgent(chosen)
                }
            }
        }
    }

    func navigate(to route: Route?) {
        guard let route else { return }
        switch route {
        case .agent(let id):
            if id != selectedAgentID || self.route != route { selectAgent(id) }
        default:
            openPanel(route)
        }
    }

    /// Opens the bot's one continuous chat and follows its event stream.
    func selectAgent(_ id: String) {
        cancelStream()
        selectionVersion += 1
        let version = selectionVersion
        selectedAgentID = id
        route = .agent(id)
        snapshot = nil
        messages = []
        hasMore = false
        oldestEntryID = ""
        loadingOlder = false
        replyTo = nil
        draft = ""
        attachments = []
        failedDraft = ""
        failedReplyTo = ""
        failedAttachments = []
        draftRequestID = ""
        request { client in
            let snapshot = try await client.chat(id)
            return { [self] in
                guard selectionVersion == version, selectedAgentID == id else { return }
                applySnapshot(snapshot)
                hasMore = snapshot.hasMore ?? false
                oldestEntryID = snapshot.oldestEntryId ?? ""
                streamTask = Task { await streamChat(client: client, id: id, version: version) }
            }
        }
    }

    /// Keeps older pages the owner already loaded; snapshots only carry the newest page.
    func applySnapshot(_ incoming: ChatSnapshot) {
        messages = mergeMessages(messages, incoming.messages ?? [])
        var snapshot = incoming
        snapshot.messages = nil
        self.snapshot = snapshot
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        streamStatus = ""
    }

    private func streamChat(client: APIClient, id: String, version: Int) async {
        var backoff = Duration.milliseconds(500)
        while !Task.isCancelled {
            do {
                try await client.chatEvents(id) { payload in
                    guard let snapshot = try? JSONDecoder().decode(ChatSnapshot.self, from: Data(payload.utf8)) else { return }
                    await MainActor.run {
                        guard self.selectionVersion == version, !Task.isCancelled else { return }
                        self.applySnapshot(snapshot)
                        self.streamStatus = ""
                        self.errorText = ""
                    }
                }
            } catch {
                if Task.isCancelled || selectionVersion != version { return }
                if let apiError = error as? APIError, apiError.statusCode == 401 {
                    errorText = friendlyError(error)
                    streamStatus = "Disconnected"
                    return
                }
                streamStatus = "Reconnecting…"
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(8))
        }
    }

    /// Follows server-wide activity for notifications, reconnecting as the chat stream does.
    func followActivity() {
        activityTask?.cancel()
        guard let client else { return }
        let generation = generation
        activityTask = Task {
            var backoff = Duration.milliseconds(500)
            while !Task.isCancelled, self.generation == generation {
                do {
                    try await client.activityEvents { payload in
                        guard let event = try? JSONDecoder().decode(ActivityEvent.self, from: Data(payload.utf8)) else { return }
                        await MainActor.run {
                            guard self.generation == generation else { return }
                            self.handleActivity(event)
                        }
                    }
                } catch {
                    if let apiError = error as? APIError, apiError.statusCode == 401 { return }
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(8))
            }
        }
    }

    func handleActivity(_ event: ActivityEvent) {
        if event.type == "chat-preview", let lastMessage = event.lastMessage,
           let index = agents.firstIndex(where: { $0.id == event.agentId }) {
            agents[index].lastMessage = lastMessage
        }
        if event.type == "approval", route == .approvals { openPanel(.approvals) }
        let context = NotificationContext(appActive: NSApp?.isActive ?? false, route: route)
        guard let note = notification(for: event, in: context) else { return }
        Notifier.shared.post(event, title: note.title, body: note.body)
    }

    func loadOlder() {
        guard !loadingOlder, hasMore, !oldestEntryID.isEmpty else { return }
        let id = selectedAgentID, before = oldestEntryID, version = selectionVersion
        loadingOlder = true
        request { client in
            do {
                let page = try await client.chatHistory(id, before: before, limit: 100)
                return { [self] in
                    guard selectionVersion == version else { return }
                    loadingOlder = false
                    messages = mergeMessages(messages, page.messages ?? [])
                    hasMore = page.hasMore ?? false
                    oldestEntryID = page.oldestEntryId ?? ""
                }
            } catch {
                if self.selectionVersion == version { self.loadingOlder = false }
                throw error
            }
        }
    }

    func sendMessage() {
        guard !sending, snapshot != nil, let client else { return }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !content.isEmpty || !files.isEmpty else { return }
        let id = selectedAgentID
        let reply = replyTo?.entryId ?? ""
        // A retry of the same draft reuses its request ID so the server admits it once.
        if draftRequestID.isEmpty || failedDraft != content || failedReplyTo != reply || failedAttachments != files.map(\.id) {
            draftRequestID = newRequestID()
        }
        let requestID = draftRequestID
        failedDraft = content
        failedReplyTo = reply
        failedAttachments = files.map(\.id)
        sending = true
        draft = ""
        attachments = []
        let generation = generation
        Task {
            do {
                try await client.sendChatMessage(id, content: content, requestID: requestID, replyTo: reply,
                                                 attachments: files.map(\.outgoing))
                sending = false
                guard self.generation == generation, selectedAgentID == id else { return }
                draftRequestID = ""
                failedDraft = ""
                failedReplyTo = ""
                failedAttachments = []
                replyTo = nil
            } catch {
                sending = false
                guard self.generation == generation, selectedAgentID == id else { return }
                errorText = "Message was not confirmed: " + friendlyError(error)
                draft = content
                attachments = files + attachments
            }
        }
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            guard attachments.count < AttachmentLimits.count else {
                errorText = "A message can carry up to \(AttachmentLimits.count) files."
                return
            }
            do {
                attachments.append(try loadAttachment(from: url))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func attachmentImage(entryID: String, index: Int) -> NSImage? {
        attachmentImages["\(entryID)/\(index)"]
    }

    func loadAttachmentImage(entryID: String, index: Int) async {
        let key = "\(entryID)/\(index)"
        guard attachmentImages[key] == nil, let client else { return }
        let agent = selectedAgentID
        guard let data = try? await client.attachment(agent, entryID: entryID, index: index), let image = NSImage(data: data) else { return }
        attachmentImages[key] = image
    }

    func abortChat() {
        let id = selectedAgentID
        request { client in
            try await client.abortChat(id)
            return nil
        }
    }

    func compactChat() {
        let id = selectedAgentID
        request { client in
            try await client.compactChat(id)
            return { [self] in showNotice("Summarizing older context") }
        }
    }

    // MARK: Agent profile

    func createAgent() {
        var draft = AgentDraft(isNew: true, agentID: "")
        draft.shuffleAvatars()
        agentDraft = draft
        loadEditorData(provider: draft.provider)
    }

    func openEditor(agentID: String? = nil) {
        guard let agent = agents.first(where: { $0.id == (agentID ?? selectedAgentID) }) else { return }
        var draft = AgentDraft(isNew: false, agentID: agent.id)
        draft.name = agent.name
        draft.description = agent.description ?? ""
        draft.instructions = agent.instructions ?? ""
        draft.model = agent.model ?? ""
        draft.provider = agent.provider ?? ""
        draft.enabled = agent.enabled
        draft.avatar = "bot:" + agentAvatarSeed(agent)
        draft.folder = agent.folder ?? ""
        if let inference = agent.inference {
            draft.thinking = inference.thinkingLevel
            draft.temperature = inference.temperature.map { String($0) } ?? ""
            draft.maxOutput = inference.maxOutputTokens.map { String($0) } ?? ""
        }
        let tools = agent.tools ?? []
        draft.toolsMemory = tools.contains("memory")
        draft.toolsDelegate = tools.contains("delegate")
        draft.toolsSchedule = tools.contains("schedule")
        draft.toolsCodemode = tools.contains("codemode")
        draft.skills = agent.skills ?? []
        draft.sharedSkills = Set(agent.sharedSkills ?? [])
        draft.sharedMemory = agent.sharedMemory ?? false
        draft.delegates = Set(agent.delegates ?? [])
        draft.mcpServers = Set(agent.mcpServers ?? [])
        draft.shuffleAvatars()
        agentDraft = draft
        loadEditorData(provider: draft.provider)
    }

    private func loadEditorData(provider: String) {
        models = []
        request { client in
            async let servers = client.mcpServers()
            async let skills = client.sharedSkills()
            let (loadedServers, loadedSkills) = try await (servers, skills)
            return { [self] in
                mcpServers = loadedServers
                sharedSkills = loadedSkills
            }
        }
        loadProviders()
        loadModels(provider)
    }

    func loadProviders() {
        request { client in
            let providers = try await client.providers()
            return { [self] in self.providers = providers }
        }
    }

    func loadModels(_ provider: String) {
        request { client in
            let models = try await client.models(provider: provider)
            return { [self] in
                guard agentDraft?.provider == provider else { return }
                self.models = models
                if agentDraft?.model.isEmpty == true, let first = models.first { agentDraft?.model = first.id }
            }
        }
    }

    func changeEditorProvider(_ provider: String) {
        agentDraft?.provider = provider
        agentDraft?.model = ""
        models = []
        loadModels(provider)
    }

    /// The server's providers, configured ones first, keeping the current choice.
    var providerChoices: [String] {
        let ordered = providers.filter(\.configured).map(\.provider) + providers.filter { !$0.configured }.map(\.provider)
        let current = agentDraft?.provider ?? ""
        return ordered.contains(current) || current.isEmpty ? ordered : [current] + ordered
    }

    var modelHint: String {
        if let provider = providers.first(where: { $0.provider == agentDraft?.provider }), !provider.configured {
            return "Add an API key for this provider in Settings to load its models."
        }
        return models.isEmpty ? "Type a model ID." : "\(models.count) models available."
    }

    func saveAgentEditor() {
        guard let draft = agentDraft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorText = "Give your agent a name."
            return
        }
        var tools: [String] = []
        if draft.toolsMemory { tools.append("memory") }
        if draft.toolsDelegate { tools.append("delegate") }
        if draft.toolsSchedule { tools.append("schedule") }
        if draft.toolsCodemode { tools.append("codemode") }
        if draft.skills.contains(where: {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.instructions.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            errorText = "Each skill needs a name and instructions."
            return
        }
        var inference = Inference(thinkingLevel: draft.thinking.isEmpty ? "off" : draft.thinking)
        if !draft.temperature.isEmpty {
            guard let value = Double(draft.temperature), (0...2).contains(value) else {
                errorText = "Temperature must be between 0 and 2."
                return
            }
            inference.temperature = value
        }
        if !draft.maxOutput.isEmpty {
            guard let value = Int(draft.maxOutput), (1...1_000_000).contains(value) else {
                errorText = "Output limit must be between 1 and 1,000,000 tokens."
                return
            }
            inference.maxOutputTokens = value
        }
        let delegates = draft.delegates.sorted(), servers = draft.mcpServers.sorted()
        let shared = draft.sharedSkills.filter { id in sharedSkills.contains { $0.id == id && !$0.isDefault } }.sorted()
        let input = Agent(name: name, description: draft.description.nilIfEmpty, instructions: draft.instructions.nilIfEmpty,
                          avatar: draft.avatar, enabled: draft.enabled, provider: draft.provider.nilIfEmpty, model: draft.model.nilIfEmpty,
                          folder: draft.folder.nilIfEmpty, tools: tools, delegates: delegates, skills: draft.skills,
                          sharedSkills: shared, sharedMemory: draft.sharedMemory, mcpServers: servers, inference: inference)
        let id = draft.agentID, isNew = draft.isNew
        request { client in
            let agent: Agent
            if isNew {
                agent = try await client.createAgent(input)
            } else {
                agent = try await client.updateAgent(id, patch: [
                    "name": .string(name), "description": .string(draft.description), "instructions": .string(draft.instructions),
                    "provider": .string(draft.provider), "model": .string(draft.model), "avatar": .string(draft.avatar),
                    "folder": .string(draft.folder), "enabled": .bool(draft.enabled), "tools": .array(tools.map(JSONValue.string)),
                    "skills": try JSONValue(encoding: draft.skills), "sharedSkills": .array(shared.map(JSONValue.string)),
                    "sharedMemory": .bool(draft.sharedMemory), "mcpServers": .array(servers.map(JSONValue.string)),
                    "delegates": .array(delegates.map(JSONValue.string)), "inference": try JSONValue(encoding: inference),
                ])
            }
            return { [self] in
                if isNew {
                    agents.append(agent)
                } else if let index = agents.firstIndex(where: { $0.id == id }) {
                    let lastMessage = agents[index].lastMessage
                    agents[index] = agent
                    agents[index].lastMessage = agent.lastMessage ?? lastMessage
                }
                agentDraft = nil
                if !isNew, let panel = route, [.memory, .skills, .integrations].contains(panel) {
                    openPanel(panel)
                } else {
                    selectAgent(agent.id)
                }
            }
        }
    }

    func duplicateSelected() {
        let id = agentDraft?.agentID ?? selectedAgentID
        request { client in
            let agent = try await client.duplicateAgent(id)
            return { [self] in
                agents.append(agent)
                agentDraft = nil
                selectAgent(agent.id)
                openEditor()
            }
        }
    }

    func deleteSelected() {
        let id = agentDraft?.agentID ?? selectedAgentID
        request { client in
            try await client.deleteAgent(id)
            return { [self] in
                agents.removeAll { $0.id == id }
                agentMemories[id] = nil
                if selectedAgentID == id {
                    cancelStream()
                    selectionVersion += 1
                    selectedAgentID = ""
                    snapshot = nil
                    messages = []
                }
                agentDraft = nil
                if let panel = route, [.memory, .skills, .integrations].contains(panel) {
                    openPanel(panel)
                } else {
                    refresh()
                }
            }
        }
    }

    // MARK: Workspace panels

    func openPanel(_ panel: Route) {
        route = panel
        memoryDraft = nil
        taskDraft = nil
        mcpDraft = nil
        skillDraft = nil
        switch panel {
        case .memory:
            memoryLoadVersion += 1
            let version = memoryLoadVersion
            request { client in
                let bots = try await client.agents()
                async let shared = client.memories(nil)
                let personal = try await withThrowingTaskGroup(of: (String, [Memory]).self) { group in
                    for bot in bots {
                        group.addTask { (bot.id, try await client.memories(bot.id)) }
                    }
                    var result: [String: [Memory]] = [:]
                    for try await (id, memories) in group { result[id] = memories }
                    return result
                }
                let sharedItems = try await shared
                return { [self] in
                    guard memoryLoadVersion == version else { return }
                    agents = bots
                    sharedMemories = sharedItems
                    agentMemories = personal
                }
            }
        case .skills:
            request { client in
                async let bots = client.agents()
                async let skills = client.sharedSkills()
                let (loadedBots, loadedSkills) = try await (bots, skills)
                return { [self] in
                    agents = loadedBots
                    sharedSkills = loadedSkills
                }
            }
        case .tasks:
            request { client in
                let items = try await client.schedules()
                return { [self] in schedules = items }
            }
        case .activity:
            request { client in
                let items = try await client.executions()
                return { [self] in executions = items }
            }
        case .approvals:
            request { client in
                let items = try await client.approvals()
                return { [self] in approvals = items }
            }
        case .integrations:
            request { client in
                async let bots = client.agents()
                async let servers = client.mcpServers()
                let (loadedBots, loadedServers) = try await (bots, servers)
                return { [self] in
                    agents = loadedBots
                    mcpServers = loadedServers
                }
            }
        case .agent:
            break
        }
    }

    /// Carries the entry's owner into the form so edits never depend on the active chat.
    func openMemoryForm(_ id: String, agentID: String? = nil) {
        let items = agentID.map { agentMemories[$0] ?? [] } ?? sharedMemories
        let existing = items.first { $0.id == id }
        memoryDraft = MemoryDraft(memoryID: id, content: existing?.content ?? "", agentID: agentID)
    }

    func saveMemory() {
        guard let form = memoryDraft else { return }
        let agent = form.agentID, content = form.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            errorText = "Memory content is required."
            return
        }
        request { client in
            if form.memoryID.isEmpty {
                _ = try await client.addMemory(agent, content: content)
            } else {
                _ = try await client.updateMemory(agent, memoryID: form.memoryID, content: content)
            }
            return { [self] in openPanel(.memory) }
        }
    }

    func deleteMemory(_ id: String, agentID: String? = nil) {
        let agent = agentID
        request { client in
            try await client.deleteMemory(agent, memoryID: id)
            return { [self] in openPanel(.memory) }
        }
    }

    func openTaskForm(_ id: String, agentID: String? = nil) {
        guard !agents.isEmpty else {
            errorText = "Create an agent before adding a task."
            return
        }
        let fallback = agents.contains { $0.id == selectedAgentID } ? selectedAgentID : agents[0].id
        var form = TaskDraft(scheduleID: id, agentID: agentID ?? fallback)
        if let schedule = schedules.first(where: { $0.id == id }) {
            form.agentID = schedule.agentId
            form.name = schedule.name
            form.prompt = schedule.prompt
            form.repeats = !(schedule.cron ?? "").isEmpty
            if let cron = schedule.cron, !cron.isEmpty { form.cron = cron }
            if let runAt = schedule.runAt {
                guard let date = taskRunDate(runAt) else {
                    errorText = "This task has an invalid run time."
                    return
                }
                form.runDate = date
            }
            form.timezone = schedule.timezone ?? TimeZone.current.identifier
            form.enabled = schedule.enabled
        }
        taskDraft = form
    }

    func saveTask() {
        guard let form = taskDraft else { return }
        let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = trim(form.name), prompt = trim(form.prompt), timezone = trim(form.timezone)
        let cron = form.repeats ? trim(form.cron) : ""
        let runAt = form.repeats ? "" : form.runDate.ISO8601Format()
        guard !form.agentID.isEmpty else {
            errorText = "Choose which bot runs this task."
            return
        }
        if let message = validateTask(name: name, prompt: prompt, cron: cron, runAt: runAt, timezone: timezone) {
            errorText = message
            return
        }
        var payload: [String: JSONValue] = ["agentId": .string(form.agentID), "name": .string(name), "prompt": .string(prompt),
                                            "timezone": .string(timezone), "enabled": .bool(form.enabled)]
        request { client in
            if form.scheduleID.isEmpty {
                if form.repeats { payload["cron"] = .string(cron) } else { payload["runAt"] = .string(runAt) }
                _ = try await client.createSchedule(payload)
            } else {
                payload["cron"] = cron.isEmpty ? .null : .string(cron)
                payload["runAt"] = form.repeats ? .null : .string(runAt)
                _ = try await client.updateSchedule(form.scheduleID, patch: payload)
            }
            return { [self] in openPanel(.tasks) }
        }
    }

    func runSchedule(_ id: String) {
        request { client in
            let execution = try await client.runSchedule(id)
            return { [self] in
                showNotice("Task started")
                if let agent = execution.agentId, !agent.isEmpty { selectAgent(agent) }
            }
        }
    }

    func deleteSchedule(_ id: String) {
        request { client in
            try await client.deleteSchedule(id)
            return { [self] in openPanel(.tasks) }
        }
    }

    func decideApproval(_ id: String, decision: String) {
        request { client in
            try await client.decideApproval(id, decision: decision)
            return { [self] in openPanel(.approvals) }
        }
    }

    /// Opens a server to edit, or a new one owned by `agentID` (nil for shared).
    func openMCPForm(_ id: String, agentID: String? = nil) {
        var form = MCPDraft(serverID: id, agentID: agentID)
        if let server = mcpServers.first(where: { $0.id == id }) {
            form.agentID = server.agentId
            form.name = server.name
            form.url = server.url
            form.enabled = server.enabled
        }
        mcpDraft = form
    }

    func saveMCP() {
        guard let form = mcpDraft else { return }
        let name = form.name.trimmingCharacters(in: .whitespaces), rawURL = form.url.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let url = URL(string: rawURL), url.host() != nil, ["http", "https"].contains(url.scheme ?? "") else {
            errorText = "MCP name and an HTTP(S) URL are required."
            return
        }
        var payload: [String: JSONValue] = ["name": .string(name), "url": .string(rawURL), "enabled": .bool(form.enabled)]
        if !form.token.isEmpty { payload["token"] = .string(form.token) }
        request { client in
            if form.serverID.isEmpty {
                if let owner = form.agentID { payload["agentId"] = .string(owner) }
                _ = try await client.createMCPServer(payload)
                // The owner starts using its new server, so its profile changed.
                if form.agentID != nil {
                    let agents = try await client.agents()
                    return { [self] in
                        self.agents = agents
                        openPanel(.integrations)
                    }
                }
            } else {
                _ = try await client.updateMCPServer(form.serverID, patch: payload)
            }
            return { [self] in openPanel(.integrations) }
        }
    }

    /// Where the system sign-in sheet returns; the sheet watches this scheme, so nothing registers it.
    static let oauthCallbackScheme = "dev.crumble.desktop"
    static let oauthRedirectURI = oauthCallbackScheme + ":/oauth/callback"

    /// Signs in to an OAuth MCP server: the server prepares the request, the system sheet shows the
    /// provider's sign-in, and the server exchanges the returned code for tokens it keeps.
    func signInToMCP(_ id: String, using session: WebAuthenticationSession) async {
        guard let client else { return }
        errorText = ""
        signingIn = id
        defer { signingIn = nil }
        do {
            let start = try await client.startMCPSignIn(id, redirectURI: Self.oauthRedirectURI)
            if let address = start.authorizationUrl, let url = URL(string: address) {
                let callback = try await session.authenticate(using: url, callbackURLScheme: Self.oauthCallbackScheme)
                let (code, state, iss) = try oauthResult(from: callback)
                _ = try await client.finishMCPSignIn(id, code: code, state: state, iss: iss)
            }
            showNotice("Signed in")
            openPanel(.integrations)
        } catch ASWebAuthenticationSessionError.canceledLogin {
            return
        } catch {
            errorText = friendlyError(error)
        }
    }

    func signOutOfMCP(_ id: String) {
        request { client in
            _ = try await client.signOutOfMCP(id)
            return { [self] in openPanel(.integrations) }
        }
    }

    func deleteMCP(_ id: String) {
        request { client in
            try await client.deleteMCPServer(id)
            return { [self] in openPanel(.integrations) }
        }
    }

    /// Servers a bot may use: the shared ones and its own.
    func usableServers(for agentID: String) -> [MCPServer] {
        mcpServers.filter { $0.agentId == nil || $0.agentId == agentID }
    }

    func openSkillForm(_ id: String) {
        var form = SkillDraft(skillID: id)
        if let skill = sharedSkills.first(where: { $0.id == id }) {
            form.name = skill.name
            form.instructions = skill.instructions
        }
        skillDraft = form
    }

    func saveSkill() {
        guard let form = skillDraft else { return }
        let name = form.name.trimmingCharacters(in: .whitespaces), instructions = form.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !instructions.isEmpty else {
            errorText = "Each skill needs a name and instructions."
            return
        }
        request { client in
            if form.skillID.isEmpty {
                _ = try await client.createSharedSkill(name: name, instructions: instructions)
            } else {
                _ = try await client.updateSharedSkill(form.skillID, name: name, instructions: instructions)
            }
            return { [self] in openPanel(.skills) }
        }
    }

    func deleteSharedSkill(_ id: String) {
        request { client in
            try await client.deleteSharedSkill(id)
            // Bots that used the skill dropped it.
            let agents = try await client.agents()
            return { [self] in
                self.agents = agents
                openPanel(.skills)
            }
        }
    }

    // MARK: Settings

    func saveSettings() {
        let rawURL = serverURL.trimmingCharacters(in: .whitespaces).trimmingTrailingSlashes
        let token = token.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: rawURL), url.host() != nil, ["http", "https"].contains(url.scheme ?? "") else {
            errorText = "Enter a valid server URL."
            return
        }
        let candidate = APIClient(baseURL: rawURL, token: token)
        Task {
            do {
                _ = try await candidate.agents()
                try Keychain.write("server-token", value: token)
                try Keychain.write("server-url", value: rawURL)
                cancelStream()
                generation += 1
                client = candidate
                activeRequests = 0
                loading = false
                errorText = ""
                selectedAgentID = ""
                showNotice("Connected")
                refresh()
                followActivity()
            } catch {
                errorText = friendlyError(error)
            }
        }
    }

    func saveProviderKey() {
        let provider = provider, key = providerKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            errorText = "Enter an API key."
            return
        }
        request { client in
            try await client.setProviderKey(provider, apiKey: key)
            return { [self] in
                providerKey = ""
                showNotice("Provider key saved")
                loadProviders()
            }
        }
    }

    func removeProviderKey() {
        let provider = provider
        request { client in
            try await client.deleteProviderKey(provider)
            return { [self] in
                showNotice("Provider key removed")
                loadProviders()
            }
        }
    }
}

// MARK: Helpers

/// Unions transcript rows by ID in entry order. Entries are immutable, so a row that scrolled
/// out of the newest snapshot page stays valid.
func mergeMessages(_ existing: [Message], _ incoming: [Message]) -> [Message] {
    var byID: [String: Message] = [:]
    for message in existing + incoming { byID[message.id] = message }
    return byID.values.sorted { messageOrder($0.id).lexicographicallyPrecedes(messageOrder($1.id)) }
}

/// Reads the entry and message index from an "agent:entry:index" row ID.
func messageOrder(_ id: String) -> [Int] {
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return [0, 0] }
    return [Int(parts[parts.count - 2]) ?? 0, Int(parts[parts.count - 1]) ?? 0]
}

func newRequestID() -> String { UUID().uuidString.lowercased() }

struct SignInError: LocalizedError {
    var errorDescription: String?
}

/// Reads the code, state and issuer from a sign-in callback, or the provider's reason for refusing.
func oauthResult(from callback: URL) throws -> (code: String, state: String, iss: String?) {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value = { (name: String) in items.first { $0.name == name }?.value }
    if let error = value("error") {
        throw SignInError(errorDescription: "Sign-in was refused: " + (value("error_description") ?? error))
    }
    guard let code = value("code"), let state = value("state") else {
        throw SignInError(errorDescription: "Sign-in returned no authorization code.")
    }
    return (code, state, value("iss"))
}

func validateTask(name: String, prompt: String, cron: String, runAt: String, timezone: String = TimeZone.current.identifier) -> String? {
    if name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty {
        return "Task name and prompt are required."
    }
    if cron.isEmpty == runAt.isEmpty {
        return "Choose either a recurring cron or a one-time run time."
    }
    if TimeZone(identifier: timezone) == nil {
        return "Choose a valid time zone."
    }
    if !runAt.isEmpty, taskRunDate(runAt) == nil {
        return "Choose a valid date and time."
    }
    return nil
}

/// Server timestamps are absolute instants; the date picker displays them in its time zone.
func taskRunDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
}

func friendlyError(_ error: Error) -> String {
    if let apiError = error as? APIError {
        if apiError.statusCode == 401 { return "Authentication failed. Check the server token in Settings." }
        struct Body: Decodable {
            struct Detail: Decodable { var message: String? }
            var error: String?
            var details: [Detail]?
        }
        if let body = try? JSONDecoder().decode(Body.self, from: Data(apiError.body.utf8)), let message = body.error, !message.isEmpty {
            if let detail = body.details?.first?.message { return message + ": " + detail }
            return message
        }
    }
    return error.localizedDescription
}

func timeLabel(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return "Today " + time }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + time
    }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func activityTime(_ value: String?) -> String {
    guard let value else { return "" }
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    guard let date = (try? fractional.parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value)) else { return value }
    return timeLabel(date)
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    var trimmingTrailingSlashes: String {
        var value = self
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
