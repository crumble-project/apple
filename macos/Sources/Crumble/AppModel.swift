import AppKit
import Foundation
import Observation

/// The window's state and the actions that change it. Network work runs in tasks that report back
/// on the main actor; results from a replaced connection or a previous agent are dropped.
@MainActor @Observable
final class AppModel {
    var serverURL = "http://127.0.0.1:7337"
    var token = ""
    private(set) var client: APIClient?
    private(set) var generation = 0

    var agents: [Agent] = []
    var route: Route? { didSet { onNotificationContextChange?() } }
    @ObservationIgnored var onNotificationContextChange: (() -> Void)?
    @ObservationIgnored var onNotificationConnectionChange: ((APIClient) -> Void)?
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
    var memoryLoadVersion = 0
    var sharedMemories: [Memory] = []
    var sharedSkills: [SharedSkill] = []
    var schedules: [Schedule] = []
    var executions: [Execution] = []
    var activities: [ActivityEntry] = []
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

    func request(_ work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?) {
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

    func clearSelectedChat() {
        cancelStream()
        selectionVersion += 1
        selectedAgentID = ""
        snapshot = nil
        messages = []
    }

    /// A tapped reply keeps its target while the initial agent-list refresh is in flight.
    func openNotificationChat(_ id: String) {
        selectAgent(id)
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

}

extension AppModel {
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
}

extension AppModel {
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
                onNotificationConnectionChange?(candidate)
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
