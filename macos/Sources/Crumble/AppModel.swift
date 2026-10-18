import AppKit
import AuthenticationServices
import Foundation
import Observation
import SwiftUI

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
    private struct PendingSend: Sendable {
        var content: String
        var replyTo: String
        var attachments: [PendingAttachment]
    }
    /// Optimistic rows and their upload payloads survive changing the selected bot.
    private var pendingMessages: [String: [Message]] = [:]
    private var pendingSends: [String: [String: PendingSend]] = [:]
    private var pendingPreviews: [String: (requestID: String, text: String)] = [:]
    /// Sent images, keyed by entry and attachment index; they never change once sent.
    private(set) var attachmentImages: [String: NSImage] = [:]

    private var activeRequests = 0
    private(set) var pendingMutations: Set<String> = []
    private(set) var mutationRevision = 0
    var loading = false
    var errorText = ""
    var notice = ""
    var streamStatus = ""
    private(set) var savingConnection = false
    private var streamTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?

    var agentMemories: [String: [Memory]] = [:]
    private var memoryLoadVersion = 0
    var sharedMemories: [Memory] = []
    var sharedSkills: [SharedSkill] = []
    var schedules: [Schedule] = []
    var executions: [Execution] = []
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

    /// Applies local intent immediately; failed requests restore only the affected record.
    func optimisticMutation(
        key: String,
        update: () -> Void,
        rollback: @escaping @MainActor () -> Void,
        work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
    ) {
        guard let client else {
            errorText = "Connect to your server in Settings."
            return
        }
        guard pendingMutations.insert(key).inserted else { return }
        let generation = generation
        mutationRevision += 1
        update()
        activeRequests += 1
        loading = true
        errorText = ""
        Task {
            do {
                let confirm = try await work(client)
                guard self.generation == generation else { return }
                pendingMutations.remove(key)
                mutationRevision += 1
                finishRequest()
                confirm?()
            } catch {
                guard self.generation == generation else { return }
                pendingMutations.remove(key)
                mutationRevision += 1
                finishRequest()
                rollback()
                errorText = friendlyError(error)
            }
        }
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
        let revision = mutationRevision
        request { client in
            let agents = try await client.agents()
            return { [self] in
                guard mutationRevision == revision, pendingMutations.isEmpty else { return }
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
        messages = pendingMessages[id] ?? []
        hasMore = false
        oldestEntryID = ""
        loadingOlder = false
        replyTo = nil
        draft = ""
        attachments = []
        failedDraft = ""
        failedReplyTo = ""
        failedAttachments = []
        sending = false
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
        let incomingMessages = incoming.messages ?? []
        let acknowledged = Set(incomingMessages.compactMap(\.requestId))
        if !acknowledged.isEmpty {
            pendingMessages[selectedAgentID]?.removeAll { acknowledged.contains($0.requestId ?? "") }
            for requestID in acknowledged {
                pendingSends[selectedAgentID]?[requestID] = nil
                if pendingPreviews[selectedAgentID]?.requestID == requestID { pendingPreviews[selectedAgentID] = nil }
            }
        }
        // Rebuild from confirmed transcript rows and append local rows so a delayed snapshot
        // cannot erase a message the user has already seen.
        let local = pendingMessages[selectedAgentID] ?? []
        messages = mergeMessages(messages.filter { $0.deliveryState == .confirmed }, incomingMessages)
        messages.append(contentsOf: local)
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
           pendingPreviews[event.agentId] == nil,
           let index = agents.firstIndex(where: { $0.id == event.agentId }) {
            agents[index].lastMessage = lastMessage
        }
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
        guard snapshot != nil, let client else { return }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !content.isEmpty || !files.isEmpty else { return }
        let id = selectedAgentID
        let reply = replyTo?.entryId ?? ""
        // Every explicit send gets its own idempotency key. Failed rows are retried through
        // retryMessage, so two identical messages must remain distinct.
        draftRequestID = newRequestID()
        let requestID = draftRequestID
        failedDraft = content
        failedReplyTo = reply
        failedAttachments = files.map(\.id)
        sending = true
        draft = ""
        attachments = []
        let optimistic = Message(
            id: "local:\(requestID)", role: "user", content: .string(content), replyTo: reply.nilIfEmpty,
            replyPreview: replyTo?.text.nilIfEmpty, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            attachments: files.map { AttachmentInfo(name: $0.name, mimeType: $0.mimeType, size: $0.data.count, kind: $0.isImage ? "image" : "file") },
            requestId: requestID, deliveryState: .sending
        )
        pendingMessages[id, default: []].append(optimistic)
        pendingSends[id, default: [:]][requestID] = PendingSend(content: content, replyTo: reply, attachments: files)
        let preview = content.nilIfEmpty ?? files.first.map { "Attachment: \($0.name)" } ?? ""
        pendingPreviews[id] = (requestID, preview)
        if let agentIndex = agents.firstIndex(where: { $0.id == id }) {
            agents[agentIndex].lastMessage = preview
        }
        if selectedAgentID == id { messages.append(optimistic) }
        // Clear the captured reply immediately; a later composer selection must survive this send.
        replyTo = nil
        let generation = generation
        let version = selectionVersion
        Task {
            do {
                try await client.sendChatMessage(id, content: content, requestID: requestID, replyTo: reply,
                                                 attachments: files.map(\.outgoing))
                guard self.generation == generation else { return }
                if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
                guard self.generation == generation, self.selectionVersion == version, selectedAgentID == id else { return }
                sending = false
                draftRequestID = ""
                failedDraft = ""
                failedReplyTo = ""
                failedAttachments = []
            } catch {
                guard self.generation == generation else { return }
                if self.selectionVersion == version, selectedAgentID == id { sending = false }
                guard pendingMessages[id]?.contains(where: { $0.requestId == requestID }) == true else { return }
                if self.selectionVersion == version, selectedAgentID == id {
                    errorText = "Message was not confirmed: " + friendlyError(error)
                }
                if let index = pendingMessages[id]?.firstIndex(where: { $0.requestId == requestID }) {
                    pendingMessages[id]?[index].deliveryState = .failed
                    if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
                    if self.selectionVersion == version, selectedAgentID == id {
                        if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
                            messages[visible].deliveryState = .failed
                        }
                    }
                }
                if self.selectionVersion == version, selectedAgentID == id {
                    // Preserve anything the user typed while this request was in flight.
                    if draft.isEmpty && attachments.isEmpty {
                        draft = content
                        attachments = files
                    }
                }
            }
        }
    }

    /// Re-sends a failed optimistic row with its original idempotency key and attachments.
    func retryMessage(_ message: Message) {
        guard message.deliveryState == .failed, let requestID = message.requestId,
              let record = pendingSends[selectedAgentID]?[requestID], let client else { return }
        guard let index = pendingMessages[selectedAgentID]?.firstIndex(where: { $0.requestId == requestID }) else { return }
        pendingMessages[selectedAgentID]?[index].deliveryState = .sending
        if let visible = messages.firstIndex(where: { $0.requestId == requestID }) { messages[visible].deliveryState = .sending }
        if draft == record.content && attachments.map(\.id) == record.attachments.map(\.id) {
            draft = ""
            attachments = []
        }
        sending = true
        let id = selectedAgentID
        let generation = generation
        let version = selectionVersion
        Task {
            do {
                try await client.sendChatMessage(id, content: record.content, requestID: requestID,
                                                 replyTo: record.replyTo, attachments: record.attachments.map(\.outgoing))
                guard self.generation == generation else { return }
                if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
                guard self.generation == generation, self.selectionVersion == version, selectedAgentID == id else { return }
                sending = false
            } catch {
                guard self.generation == generation else { return }
                if self.selectionVersion == version, selectedAgentID == id { sending = false }
                guard pendingMessages[id]?.contains(where: { $0.requestId == requestID }) == true else { return }
                if self.selectionVersion == version, selectedAgentID == id {
                    errorText = "Message was not confirmed: " + friendlyError(error)
                }
                if let index = pendingMessages[id]?.firstIndex(where: { $0.requestId == requestID }) {
                    pendingMessages[id]?[index].deliveryState = .failed
                    if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
                    if self.selectionVersion == version, selectedAgentID == id,
                       let visible = messages.firstIndex(where: { $0.requestId == requestID }) { messages[visible].deliveryState = .failed }
                }
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

    /// Drops client-only optimistic rows and payloads when switching server connections.
    /// The next chat snapshot becomes the sole source of truth.
    func resetPendingMessages() {
        pendingMessages.removeAll()
        pendingSends.removeAll()
        pendingPreviews.removeAll()
        messages.removeAll()
        draftRequestID = ""
        failedDraft = ""
        failedReplyTo = ""
        failedAttachments = []
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func attachmentImage(entryID: String, index: Int) -> NSImage? {
        attachmentImages["\(entryID)/\(index)"]
    }

    func attachmentImage(message: Message, index: Int) -> NSImage? {
        if let entryID = message.entryId { return attachmentImage(entryID: entryID, index: index) }
        guard let requestID = message.requestId,
              let files = pendingSends[selectedAgentID]?[requestID]?.attachments,
              files.indices.contains(index), files[index].isImage else { return nil }
        return NSImage(data: files[index].data)
    }

    func loadAttachmentImage(entryID: String, index: Int) async {
        let key = "\(entryID)/\(index)"
        guard attachmentImages[key] == nil, let client else { return }
        guard !entryID.hasPrefix("local:") else { return }
        let agent = selectedAgentID
        guard let data = try? await client.attachment(agent, entryID: entryID, index: index), let image = NSImage(data: data) else { return }
        attachmentImages[key] = image
    }

    func abortChat() {
        let id = selectedAgentID
        optimisticMutation(key: "abort:\(id)", update: { [self] in
            showNotice("Stopping…")
        }, rollback: {}, work: { client in
            try await client.abortChat(id)
            return nil
        })
    }

    func compactChat() {
        let id = selectedAgentID
        optimisticMutation(key: "compact:\(id)", update: { [self] in
            showNotice("Summarizing older context…")
        }, rollback: {}, work: { client in
            try await client.compactChat(id)
            return nil
        })
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
        let revision = mutationRevision
        request { client in
            async let servers = client.mcpServers()
            async let skills = client.sharedSkills()
            let (loadedServers, loadedSkills) = try await (servers, skills)
            return { [self] in
                guard mutationRevision == revision, pendingMutations.isEmpty else { return }
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
        let isNew = draft.isNew
        let id = isNew ? "pending:" + newRequestID() : draft.agentID
        let old = agents.first { $0.id == id }
        var provisional = input
        provisional.id = id
        provisional.lastMessage = old?.lastMessage
        let originalRoute = route
        optimisticMutation(key: "agent:\(id)", update: { [self] in
            if let index = agents.firstIndex(where: { $0.id == id }) {
                agents[index] = provisional
            } else {
                agents.append(provisional)
            }
            agentDraft = nil
        }, rollback: { [self] in
            if let old, let index = agents.firstIndex(where: { $0.id == id }) {
                agents[index] = old
            } else {
                agents.removeAll { $0.id == id }
            }
            if agentDraft == nil, route == originalRoute { agentDraft = draft }
        }, work: { client in
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
                if let index = agents.firstIndex(where: { $0.id == id }) {
                    let lastMessage = agents[index].lastMessage
                    agents[index] = agent
                    agents[index].lastMessage = agent.lastMessage ?? lastMessage
                }
                if isNew, route == originalRoute, agentDraft == nil {
                    selectAgent(agent.id)
                }
            }
        })
    }

    func duplicateSelected() {
        let id = agentDraft?.agentID ?? selectedAgentID
        guard var copy = agents.first(where: { $0.id == id }), !id.hasPrefix("pending:") else { return }
        let temporaryID = "pending:" + newRequestID()
        copy.id = temporaryID
        copy.name += " copy"
        copy.lastMessage = nil
        let originalRoute = route, originalDraft = agentDraft
        optimisticMutation(key: "agent:\(temporaryID)", update: { [self] in
            agents.append(copy)
            agentDraft = nil
        }, rollback: { [self] in
            agents.removeAll { $0.id == temporaryID }
            if agentDraft == nil, route == originalRoute { agentDraft = originalDraft }
        }, work: { client in
            let agent = try await client.duplicateAgent(id)
            return { [self] in
                if let index = agents.firstIndex(where: { $0.id == temporaryID }) { agents[index] = agent }
                if route == originalRoute, agentDraft == nil {
                    selectAgent(agent.id)
                    openEditor()
                }
            }
        })
    }

    func deleteSelected() {
        let id = agentDraft?.agentID ?? selectedAgentID
        guard !id.hasPrefix("pending:"), let index = agents.firstIndex(where: { $0.id == id }) else { return }
        let removed = agents[index], memories = agentMemories[id]
        let wasSelected = selectedAgentID == id
        var routeAfterDeletion = route
        optimisticMutation(key: "agent:\(id)", update: { [self] in
            agents.removeAll { $0.id == id }
            agentMemories[id] = nil
            agentDraft = nil
            if wasSelected {
                cancelStream()
                selectionVersion += 1
                selectedAgentID = ""
                snapshot = nil
                messages = []
                if case .agent = route {
                    if let next = agents.first { selectAgent(next.id) } else { route = nil }
                }
            }
            routeAfterDeletion = route
        }, rollback: { [self] in
            agents.insert(removed, at: min(index, agents.count))
            agentMemories[id] = memories
            if wasSelected, route == routeAfterDeletion { selectAgent(id) }
        }, work: { client in
            try await client.deleteAgent(id)
            return nil
        })
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
            let mutationVersion = mutationRevision
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
                    guard memoryLoadVersion == version, mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
                    agents = bots
                    sharedMemories = sharedItems
                    agentMemories = personal
                }
            }
        case .skills:
            let mutationVersion = mutationRevision
            request { client in
                async let bots = client.agents()
                async let skills = client.sharedSkills()
                let (loadedBots, loadedSkills) = try await (bots, skills)
                return { [self] in
                    guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
                    agents = loadedBots
                    sharedSkills = loadedSkills
                }
            }
        case .tasks:
            let mutationVersion = mutationRevision
            request { client in
                let items = try await client.schedules()
                return { [self] in
                    guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
                    schedules = items
                }
            }
        case .activity:
            request { client in
                let items = try await client.executions()
                return { [self] in executions = items }
            }
        case .integrations:
            let mutationVersion = mutationRevision
            request { client in
                async let bots = client.agents()
                async let servers = client.mcpServers()
                let (loadedBots, loadedServers) = try await (bots, servers)
                return { [self] in
                    guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
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
        let isNew = form.memoryID.isEmpty
        let provisionalID = isNew ? "pending-memory-" + newRequestID() : form.memoryID
        let provisional = Memory(id: provisionalID, content: content, createdAt: nil)
        let old = (agent == nil ? sharedMemories : agentMemories[agent!] ?? []).first { $0.id == form.memoryID }
        memoryDraft = nil
        optimisticMutation(key: "memory:\(provisionalID)", update: { [self] in
            if agent == nil {
                if let index = sharedMemories.firstIndex(where: { $0.id == provisionalID || $0.id == form.memoryID }) { sharedMemories[index] = provisional }
                else { sharedMemories.append(provisional) }
            } else {
                var items = agentMemories[agent!] ?? []
                if let index = items.firstIndex(where: { $0.id == provisionalID || $0.id == form.memoryID }) { items[index] = provisional }
                else { items.append(provisional) }
                agentMemories[agent!] = items
            }
        }, rollback: { [self] in
            if agent == nil {
                sharedMemories.removeAll { $0.id == provisionalID }
                if let old { sharedMemories.append(old) }
            } else {
                var items = agentMemories[agent!] ?? []
                items.removeAll { $0.id == provisionalID }
                if let old { items.append(old) }
                agentMemories[agent!] = items
            }
            if route == .memory, memoryDraft == nil { memoryDraft = form }
        }, work: { client in
            let saved = isNew ? try await client.addMemory(agent, content: content) : try await client.updateMemory(agent, memoryID: form.memoryID, content: content)
            return { [self] in
                if agent == nil {
                    if let index = sharedMemories.firstIndex(where: { $0.id == provisionalID }) { sharedMemories[index] = saved }
                } else if var items = agentMemories[agent!], let index = items.firstIndex(where: { $0.id == provisionalID }) {
                    items[index] = saved; agentMemories[agent!] = items
                }
            }
        })
    }

    func deleteMemory(_ id: String, agentID: String? = nil) {
        let agent = agentID
        let old = (agent == nil ? sharedMemories : agentMemories[agent!] ?? []).first { $0.id == id }
        let oldIndex = (agent == nil ? sharedMemories : agentMemories[agent!] ?? []).firstIndex { $0.id == id }
        optimisticMutation(key: "memory:\(id)", update: { [self] in
            if agent == nil { sharedMemories.removeAll { $0.id == id } }
            else { agentMemories[agent!]?.removeAll { $0.id == id } }
        }, rollback: { [self] in
            guard let old else { return }
            if agent == nil { sharedMemories.insert(old, at: min(oldIndex ?? sharedMemories.count, sharedMemories.count)) }
            else {
                var items = agentMemories[agent!] ?? []
                items.insert(old, at: min(oldIndex ?? items.count, items.count)); agentMemories[agent!] = items
            }
        }, work: { client in
            try await client.deleteMemory(agent, memoryID: id)
            return nil
        })
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
        let isNew = form.scheduleID.isEmpty
        let provisionalID = isNew ? "pending-schedule-" + newRequestID() : form.scheduleID
        let provisional = Schedule(id: provisionalID, agentId: form.agentID, name: name, cron: form.repeats ? cron : nil,
                                   prompt: prompt, timezone: timezone, runAt: form.repeats ? nil : runAt, enabled: form.enabled, createdByAgentId: nil)
        let old = schedules.first { $0.id == form.scheduleID }
        taskDraft = nil
        optimisticMutation(key: "schedule:\(provisionalID)", update: { [self] in
            if let index = schedules.firstIndex(where: { $0.id == provisionalID || $0.id == form.scheduleID }) { schedules[index] = provisional }
            else { schedules.append(provisional) }
        }, rollback: { [self] in
            schedules.removeAll { $0.id == provisionalID }
            if let old { schedules.append(old) }
            if route == .tasks, taskDraft == nil { taskDraft = form }
        }, work: { client in
            if isNew {
                if form.repeats { payload["cron"] = .string(cron) } else { payload["runAt"] = .string(runAt) }
                let saved = try await client.createSchedule(payload)
                return { [self] in if let index = schedules.firstIndex(where: { $0.id == provisionalID }) { schedules[index] = saved } }
            } else {
                payload["cron"] = cron.isEmpty ? .null : .string(cron)
                payload["runAt"] = form.repeats ? .null : .string(runAt)
                let saved = try await client.updateSchedule(form.scheduleID, patch: payload)
                return { [self] in if let index = schedules.firstIndex(where: { $0.id == provisionalID }) { schedules[index] = saved } }
            }
        })
    }

    func runSchedule(_ id: String) {
        let routeAtStart = route
        showNotice("Starting task…")
        optimisticMutation(key: "schedule-run:\(id)", update: {}, rollback: { [self] in
            showNotice("Task could not be started")
        }, work: { client in
            let execution = try await client.runSchedule(id)
            return { [self] in
                showNotice("Task started")
                if route == routeAtStart, routeAtStart == .tasks,
                   let agent = execution.agentId, !agent.isEmpty { selectAgent(agent) }
            }
        })
    }

    func deleteSchedule(_ id: String) {
        guard let old = schedules.first(where: { $0.id == id }), let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        optimisticMutation(key: "schedule:\(id)", update: { [self] in schedules.removeAll { $0.id == id } }, rollback: { [self] in schedules.insert(old, at: min(index, schedules.count)) }, work: { client in
            try await client.deleteSchedule(id); return nil
        })
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
        let isNew = form.serverID.isEmpty
        let provisionalID = isNew ? "pending-mcp-" + newRequestID() : form.serverID
        let old = mcpServers.first { $0.id == form.serverID }
        var provisional = MCPServer(id: provisionalID, name: name, url: rawURL, enabled: form.enabled, agentId: form.agentID, authenticated: false, auth: form.token.isEmpty ? "none" : "token")
        if let old, form.token.isEmpty, old.url == rawURL {
            provisional.authenticated = old.authenticated
            provisional.auth = old.auth
        }
        let owner = form.agentID
        mcpDraft = nil
        optimisticMutation(key: "mcp:\(provisionalID)", update: { [self] in
            if let index = mcpServers.firstIndex(where: { $0.id == provisionalID || $0.id == form.serverID }) { mcpServers[index] = provisional }
            else { mcpServers.append(provisional) }
            if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
                var memberships = agents[index].mcpServers ?? []
                if !memberships.contains(provisionalID) { memberships.append(provisionalID) }
                agents[index].mcpServers = memberships
            }
        }, rollback: { [self] in
            mcpServers.removeAll { $0.id == provisionalID }
            if let old { mcpServers.append(old) }
            if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
                agents[index].mcpServers?.removeAll { $0 == provisionalID }
            }
            if route == .integrations, mcpDraft == nil { mcpDraft = form }
        }, work: { client in
            if isNew {
                if let owner = form.agentID { payload["agentId"] = .string(owner) }
                let saved = try await client.createMCPServer(payload)
                return { [self] in
                    if let index = mcpServers.firstIndex(where: { $0.id == provisionalID }) { mcpServers[index] = saved }
                    if let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
                        agents[index].mcpServers = (agents[index].mcpServers ?? []).map { $0 == provisionalID ? saved.id : $0 }
                    }
                }
            }
            let saved = try await client.updateMCPServer(form.serverID, patch: payload)
            return { [self] in if let index = mcpServers.firstIndex(where: { $0.id == provisionalID }) { mcpServers[index] = saved } }
        })
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
        let generationAtStart = generation
        defer { if generation == generationAtStart, signingIn == id { signingIn = nil } }
        do {
            let start = try await client.startMCPSignIn(id, redirectURI: Self.oauthRedirectURI)
            guard generation == generationAtStart else { return }
            if let address = start.authorizationUrl, let url = URL(string: address) {
                let callback = try await session.authenticate(using: url, callbackURLScheme: Self.oauthCallbackScheme)
                let (code, state, iss) = try oauthResult(from: callback)
                guard generation == generationAtStart else { return }
                let saved = try await client.finishMCPSignIn(id, code: code, state: state, iss: iss)
                guard generation == generationAtStart else { return }
                if let index = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[index] = saved }
            } else if start.authorized == true, let index = mcpServers.firstIndex(where: { $0.id == id }) {
                mcpServers[index].authenticated = true
            }
            showNotice("Signed in")
        } catch ASWebAuthenticationSessionError.canceledLogin {
            return
        } catch {
            guard generation == generationAtStart else { return }
            errorText = friendlyError(error)
        }
    }

    func signOutOfMCP(_ id: String) {
        guard let old = mcpServers.first(where: { $0.id == id }), let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        var signedOut = old
        signedOut.authenticated = false
        signedOut.auth = "none"
        optimisticMutation(key: "mcp:\(id)", update: { [self] in mcpServers[index] = signedOut }, rollback: { [self] in
            if let current = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[current] = old }
        }, work: { client in
            let saved = try await client.signOutOfMCP(id)
            return { [self] in if let current = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[current] = saved } }
        })
    }

    func deleteMCP(_ id: String) {
        guard let old = mcpServers.first(where: { $0.id == id }), let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        let affectedAgents = agents.compactMap { agent -> (String, [String])? in
            guard agent.mcpServers?.contains(id) == true else { return nil }
            return (agent.id, agent.mcpServers ?? [])
        }
        optimisticMutation(key: "mcp:\(id)", update: { [self] in
            mcpServers.removeAll { $0.id == id }
            for (agentID, _) in affectedAgents {
                if let index = agents.firstIndex(where: { $0.id == agentID }) { agents[index].mcpServers?.removeAll { $0 == id } }
            }
        }, rollback: { [self] in
            mcpServers.insert(old, at: min(index, mcpServers.count))
            for (agentID, memberships) in affectedAgents {
                if let index = agents.firstIndex(where: { $0.id == agentID }) { agents[index].mcpServers = memberships }
            }
        }, work: { client in
            try await client.deleteMCPServer(id); return nil
        })
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
        let isNew = form.skillID.isEmpty
        let provisionalID = isNew ? "pending-skill-" + newRequestID() : form.skillID
        let provisional = SharedSkill(id: provisionalID, name: name, instructions: instructions, source: nil, path: nil)
        let old = sharedSkills.first { $0.id == form.skillID }
        skillDraft = nil
        optimisticMutation(key: "skill:\(provisionalID)", update: { [self] in
            if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID || $0.id == form.skillID }) { sharedSkills[index] = provisional }
            else { sharedSkills.append(provisional) }
        }, rollback: { [self] in
            sharedSkills.removeAll { $0.id == provisionalID }
            if let old { sharedSkills.append(old) }
            if route == .skills, skillDraft == nil { skillDraft = form }
        }, work: { client in
            if isNew {
                let saved = try await client.createSharedSkill(name: name, instructions: instructions)
                return { [self] in if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID }) { sharedSkills[index] = saved } }
            }
            let saved = try await client.updateSharedSkill(form.skillID, name: name, instructions: instructions)
            return { [self] in if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID }) { sharedSkills[index] = saved } }
        })
    }

    func deleteSharedSkill(_ id: String) {
        guard let old = sharedSkills.first(where: { $0.id == id }), let index = sharedSkills.firstIndex(where: { $0.id == id }) else { return }
        let affectedAgents = agents.compactMap { agent -> (String, [String])? in
            guard agent.sharedSkills?.contains(id) == true else { return nil }
            return (agent.id, agent.sharedSkills ?? [])
        }
        optimisticMutation(key: "skill:\(id)", update: { [self] in
            sharedSkills.removeAll { $0.id == id }
            for index in agents.indices { agents[index].sharedSkills?.removeAll { $0 == id } }
        }, rollback: { [self] in
            sharedSkills.insert(old, at: min(index, sharedSkills.count))
            for (agentID, memberships) in affectedAgents {
                if let index = agents.firstIndex(where: { $0.id == agentID }) { agents[index].sharedSkills = memberships }
            }
        }, work: { client in
            try await client.deleteSharedSkill(id)
            return nil
        })
    }

    // MARK: Settings

    func saveSettings() {
        guard !savingConnection else { return }
        let rawURL = serverURL.trimmingCharacters(in: .whitespaces).trimmingTrailingSlashes
        let token = token.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: rawURL), url.host() != nil, ["http", "https"].contains(url.scheme ?? "") else {
            errorText = "Enter a valid server URL."
            return
        }
        let candidate = APIClient(baseURL: rawURL, token: token)
        savingConnection = true
        errorText = ""
        Task {
            defer { savingConnection = false }
            do {
                _ = try await candidate.agents()
                try Keychain.write("server-token", value: token)
                try Keychain.write("server-url", value: rawURL)
                cancelStream()
                generation += 1
                pendingMutations.removeAll()
                mutationRevision += 1
                resetPendingMessages()
                agents = []
                agentMemories = [:]
                sharedMemories = []
                sharedSkills = []
                schedules = []
                executions = []
                mcpServers = []
                providers = []
                models = []
                signingIn = nil
                agentDraft = nil
                memoryDraft = nil
                taskDraft = nil
                mcpDraft = nil
                skillDraft = nil
                snapshot = nil
                messages = []
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
        optimisticMutation(key: "provider:\(provider)", update: { [self] in
            providerKey = ""
        }, rollback: { [self] in
            if self.provider == provider, providerKey.isEmpty { providerKey = key }
        }, work: { client in
            try await client.setProviderKey(provider, apiKey: key)
            return { [self] in
                showNotice("Provider key saved")
                loadProviders()
            }
        })
    }

    func removeProviderKey() {
        let provider = provider
        optimisticMutation(key: "provider:\(provider)", update: {}, rollback: {}, work: { client in
            try await client.deleteProviderKey(provider)
            return { [self] in
                showNotice("Provider key removed")
                loadProviders()
            }
        })
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
