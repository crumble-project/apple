import apfelkern
import AppKit
import Foundation

extension AppModel {
    // MARK: Agents and chat

    func refresh() {
        let revision = mutationRevision
        request { client in
            let agents = try await client.agents()
            return { [self] in
                guard mutationRevision == revision, pendingMutations.isEmpty else { return }
                self.agents = agents
                loadCapabilities()
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
        stopFollowingBackgroundChat(id)
        selectionVersion += 1
        let version = selectionVersion
        selectedAgentID = id
        route = .agent(id)
        snapshot = nil
        messages = delivery.messages(botID: id)
        hasMore = false
        oldestEntryID = ""
        loadingOlder = false
        replyTo = nil
        codingJobs = [:]
        codingActivity = 0
        codingJobHistory = nil
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
        updateRunningBot(selectedAgentID, running: incoming.isRunning)
        let incomingMessages = incoming.messages ?? []
        let acknowledged = Set(incomingMessages.compactMap(\.requestId))
        delivery.acknowledge(botID: selectedAgentID, requestIDs: acknowledged)
        // Rebuild from confirmed transcript rows and append local rows so a delayed snapshot
        // cannot erase a message the user has already seen.
        let local = delivery.messages(botID: selectedAgentID)
        messages = mergeMessages(messages.filter { $0.deliveryState == .confirmed }, incomingMessages)
        messages.append(contentsOf: local)
        refreshCodingJobsIfChanged()
        var snapshot = incoming
        snapshot.messages = nil
        self.snapshot = snapshot
    }

    func cancelStream(preservingWork: Bool = true) {
        if preservingWork, runningAgentIDs.contains(selectedAgentID) {
            followBackgroundChat(selectedAgentID)
        }
        streamTask?.cancel()
        streamTask = nil
        streamStatus = ""
    }

    private func streamChat(client: APIClient, id: String, version: Int) async {
        var backoff = Duration.milliseconds(500)
        while !Task.isCancelled {
            do {
                try await client.chatEvents(id) { payload in
                    guard let snapshot = try? JSONDecoder().decode(ChatSnapshot.self, from: Data(payload.utf8)) else {
                        return
                    }
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
                        guard let event = try? JSONDecoder().decode(ActivityEvent.self, from: Data(payload.utf8)) else {
                            return
                        }
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
            delivery.preview(botID: event.agentId) == nil,
            let index = agents.firstIndex(where: { $0.id == event.agentId }) {
            agents[index].lastMessage = lastMessage
        }
        let context = NotificationContext(appActive: NSApp?.isActive ?? false, route: route)
        guard let note = notification(for: event, in: context) else { return }
        Notifier.shared.post(event, title: note.title, body: note.body)
    }

    func loadOlder() {
        guard !loadingOlder, hasMore, !oldestEntryID.isEmpty else { return }
        let id = selectedAgentID
        let before = oldestEntryID
        let version = selectionVersion
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
        delivery.reset()
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
            let data = delivery.imageData(botID: selectedAgentID, requestID: requestID, index: index)
        else { return nil }
        return NSImage(data: data)
    }

    func loadAttachmentImage(entryID: String, index: Int) async {
        let key = "\(entryID)/\(index)"
        guard attachmentImages[key] == nil, let client else { return }
        guard !entryID.hasPrefix("local:") else { return }
        let agent = selectedAgentID
        guard let data = try? await client.attachment(agent, entryID: entryID, index: index),
            let image = NSImage(data: data)
        else { return }
        attachmentImages[key] = image
    }

    func abortChat() {
        let id = selectedAgentID
        optimisticMutation(
            key: "abort:\(id)",
            update: { [self] in
                showNotice("Stopping…")
            }, rollback: {},
            work: { client in
                try await client.abortChat(id)
                return nil
            })
    }

    func compactChat() {
        let id = selectedAgentID
        optimisticMutation(
            key: "compact:\(id)",
            update: { [self] in
                showNotice("Summarizing older context…")
            }, rollback: {},
            work: { client in
                try await client.compactChat(id)
                return nil
            })
    }
}
