import AppKit
import Foundation
import Observation

enum Route: Hashable {
    case agent(String)
    case memory, tasks, activity, approvals, integrations

    var title: String {
        switch self {
        case .agent: "Chat"
        case .memory: "Memory"
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
    var delegates: Set<String> = []
    var mcpServers: Set<String> = []
    var skills: [Skill] = []

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
}

struct TaskDraft: Identifiable, Sendable {
    let id = UUID()
    var scheduleID: String
    var agentID: String
    var name = ""
    var prompt = ""
    var cron = ""
    var runAt = ""
    var timezone = TimeZone.current.identifier
    var enabled = true
}

struct MCPDraft: Identifiable, Sendable {
    let id = UUID()
    var serverID: String
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

    var memories: [Memory] = []
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

    func openEditor() {
        guard let agent = selectedAgent else { return }
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
        draft.skills = agent.skills ?? []
        draft.delegates = Set(agent.delegates ?? [])
        draft.mcpServers = Set(agent.mcpServers ?? [])
        draft.shuffleAvatars()
        agentDraft = draft
        loadEditorData(provider: draft.provider)
    }

    private func loadEditorData(provider: String) {
        models = []
        request { client in
            let servers = try await client.mcpServers()
            return { [self] in mcpServers = servers }
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
        let input = Agent(name: name, description: draft.description.nilIfEmpty, instructions: draft.instructions.nilIfEmpty,
                          avatar: draft.avatar, enabled: draft.enabled, provider: draft.provider.nilIfEmpty, model: draft.model.nilIfEmpty,
                          folder: draft.folder.nilIfEmpty, tools: tools, delegates: delegates, skills: draft.skills,
                          mcpServers: servers, inference: inference)
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
                    "skills": try JSONValue(encoding: draft.skills), "mcpServers": .array(servers.map(JSONValue.string)),
                    "delegates": .array(delegates.map(JSONValue.string)), "inference": try JSONValue(encoding: inference),
                ])
            }
            return { [self] in
                if isNew {
                    agents.append(agent)
                } else if let index = agents.firstIndex(where: { $0.id == id }) {
                    agents[index] = agent
                }
                agentDraft = nil
                selectAgent(agent.id)
            }
        }
    }

    func duplicateSelected() {
        let id = selectedAgentID
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
        let id = selectedAgentID
        request { client in
            try await client.deleteAgent(id)
            return { [self] in
                selectedAgentID = ""
                agentDraft = nil
                refresh()
            }
        }
    }

    // MARK: Workspace panels

    func openPanel(_ panel: Route) {
        route = panel
        memoryDraft = nil
        taskDraft = nil
        mcpDraft = nil
        let selected = selectedAgentID
        switch panel {
        case .memory:
            guard !selected.isEmpty else { return }
            request { client in
                let items = try await client.memories(selected)
                return { [self] in if selectedAgentID == selected { memories = items } }
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
                let items = try await client.mcpServers()
                return { [self] in mcpServers = items }
            }
        case .agent:
            break
        }
    }

    func openMemoryForm(_ id: String) {
        memoryDraft = MemoryDraft(memoryID: id, content: memories.first { $0.id == id }?.content ?? "")
    }

    func saveMemory() {
        guard let form = memoryDraft else { return }
        let agent = selectedAgentID, content = form.content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func deleteMemory(_ id: String) {
        let agent = selectedAgentID
        request { client in
            try await client.deleteMemory(agent, memoryID: id)
            return { [self] in openPanel(.memory) }
        }
    }

    func openTaskForm(_ id: String) {
        guard !selectedAgentID.isEmpty else {
            errorText = "Select an agent before creating a task."
            return
        }
        var form = TaskDraft(scheduleID: id, agentID: selectedAgentID)
        if let schedule = schedules.first(where: { $0.id == id }) {
            form.agentID = schedule.agentId
            form.name = schedule.name
            form.prompt = schedule.prompt
            form.cron = schedule.cron ?? ""
            form.runAt = schedule.runAt ?? ""
            form.timezone = schedule.timezone ?? ""
            form.enabled = schedule.enabled
        }
        taskDraft = form
    }

    func saveTask() {
        guard let form = taskDraft else { return }
        let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = trim(form.name), prompt = trim(form.prompt), cron = trim(form.cron), runAt = trim(form.runAt), timezone = trim(form.timezone)
        if let message = validateTask(name: name, prompt: prompt, cron: cron, runAt: runAt) {
            errorText = message
            return
        }
        var payload: [String: JSONValue] = ["agentId": .string(form.agentID), "name": .string(name), "prompt": .string(prompt),
                                            "timezone": .string(timezone), "enabled": .bool(form.enabled)]
        request { client in
            if form.scheduleID.isEmpty {
                if cron.isEmpty { payload["runAt"] = .string(runAt) } else { payload["cron"] = .string(cron) }
                _ = try await client.createSchedule(payload)
            } else {
                payload["cron"] = cron.isEmpty ? .null : .string(cron)
                payload["runAt"] = cron.isEmpty ? .string(runAt) : .null
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

    func openMCPForm(_ id: String) {
        var form = MCPDraft(serverID: id)
        if let server = mcpServers.first(where: { $0.id == id }) {
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
                _ = try await client.createMCPServer(payload)
            } else {
                _ = try await client.updateMCPServer(form.serverID, patch: payload)
            }
            return { [self] in openPanel(.integrations) }
        }
    }

    func deleteMCP(_ id: String) {
        request { client in
            try await client.deleteMCPServer(id)
            return { [self] in openPanel(.integrations) }
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

func validateTask(name: String, prompt: String, cron: String, runAt: String) -> String? {
    if name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty {
        return "Task name and prompt are required."
    }
    if cron.isEmpty == runAt.isEmpty {
        return "Choose either a recurring cron or a one-time run time."
    }
    if !runAt.isEmpty, (try? Date.ISO8601FormatStyle().parse(runAt)) == nil {
        return "Use a complete date and time with a time zone, such as 2026-10-18T09:00:00Z."
    }
    return nil
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
