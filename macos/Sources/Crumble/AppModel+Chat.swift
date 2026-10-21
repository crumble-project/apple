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
                loadGroupChats()
                // An open group chat stays open; the bot list only refreshes.
                guard selectedGroupID.isEmpty else { return }
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
        case .group(let id):
            if id != selectedGroupID || self.route != route { selectGroup(id) }
        default:
            openPanel(route)
        }
    }

    /// Opens the bot's one continuous chat and follows its event stream.
    func selectAgent(_ id: String) {
        leaveGroup()
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
        jobs = [:]
        jobActivity = 0
        jobHistory = nil
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

    /// A tapped reply keeps its target while the initial agent-list refresh is in flight. A bot
    /// missing from the list is looked up again, since it may be newer than the list or deleted.
    func openNotificationChat(_ id: String) {
        guard !agents.contains(where: { $0.id == id }) else {
            selectAgent(id)
            return
        }
        request { client in
            let agents = try await client.agents()
            return { [self] in
                guard agents.contains(where: { $0.id == id }) else {
                    errorText = "The bot for this notification no longer exists."
                    return
                }
                if pendingMutations.isEmpty { self.agents = agents }
                selectAgent(id)
            }
        }
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
        refreshJobsIfChanged()
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
                            if self.activityNeedsReconcile {
                                self.activityNeedsReconcile = false
                                self.reconcileAgents()
                            }
                            self.handleActivity(event)
                        }
                    }
                } catch {
                    if let apiError = error as? APIError, apiError.statusCode == 401 { return }
                }
                // Finished replies are not replayed, so missed ones are recovered from the server.
                activityNeedsReconcile = true
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
        let context = NotificationContext(windowOnScreen: mainWindowOnScreen(), route: route)
        guard let client, let note = notification(for: event, in: context) else { return }
        notifier.post(event, title: note.title, body: note.body, serverURL: client.baseURL)
    }

    /// Restarts every server stream after wake or a network change. Chat streams resend a snapshot
    /// on connection, which reconciles the transcript and running state.
    func reconnectStreams() {
        guard let client else { return }
        activityNeedsReconcile = true
        followActivity()
        reconnectGroupStream()
        if streamTask != nil, !selectedAgentID.isEmpty {
            streamTask?.cancel()
            let id = selectedAgentID
            let version = selectionVersion
            streamTask = Task { await streamChat(client: client, id: id, version: version) }
        }
        for id in backgroundChats.keys {
            stopFollowingBackgroundChat(id)
            followBackgroundChat(id)
        }
    }

    /// Reloads the bot list after the activity stream may have missed events. The stream replays
    /// previews on connection, but not bots created or deleted meanwhile.
    func reconcileAgents() {
        guard let client else { return }
        let generation = generation
        let revision = mutationRevision
        Task {
            guard let agents = try? await client.agents(), self.generation == generation,
                mutationRevision == revision, pendingMutations.isEmpty else { return }
            if !selectedAgentID.isEmpty, !agents.contains(where: { $0.id == selectedAgentID }) {
                refresh()
                return
            }
            self.agents = agents
            loadGroupChats()
        }
    }

    func loadOlder() {
        guard selectedGroupID.isEmpty else { return loadOlderGroupMessages() }
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
        let key = selectedGroupID.isEmpty ? selectedAgentID : Self.groupKey(selectedGroupID)
        guard let requestID = message.requestId,
            let data = delivery.imageData(botID: key, requestID: requestID, index: index)
        else { return nil }
        return NSImage(data: data)
    }

    func loadAttachmentImage(entryID: String, index: Int) async {
        let key = "\(entryID)/\(index)"
        guard attachmentImages[key] == nil, let client else { return }
        guard !entryID.hasPrefix("local:") else { return }
        let agent = selectedAgentID
        let group = selectedGroupID
        let data = group.isEmpty
            ? try? await client.attachment(agent, entryID: entryID, index: index)
            : try? await client.groupAttachment(group, entryID: entryID, index: index)
        guard let data,
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
