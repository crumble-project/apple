import apfelkern
import AppKit
import Foundation

/// The group a sheet creates or edits: its name and two to six member bots.
struct GroupDraft: Identifiable, Sendable {
    let id = UUID()
    /// Nil for a new group.
    var groupID: String?
    var name = ""
    var memberIDs: [String] = []

    static let memberRange = 2...6

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Self.memberRange.contains(memberIDs.count)
    }
}

extension AppModel {
    /// Optimistic group messages share bot chat delivery under a key no bot ID can take.
    static func groupKey(_ id: String) -> String { "group:" + id }

    /// Loads the group list quietly: a server without group chats, or a failed load, leaves the list as it is.
    func loadGroupChats() {
        guard let client else { return }
        let generation = generation
        let revision = mutationRevision
        Task {
            guard let groups = try? await client.groupChats(), self.generation == generation,
                mutationRevision == revision, pendingMutations.isEmpty
            else { return }
            groupChats = groups
            if !selectedGroupID.isEmpty, !groups.contains(where: { $0.id == selectedGroupID }) {
                leaveGroup()
                route = nil
            }
        }
    }

    /// Opens a group chat and follows its event stream; the bot chat, if any, keeps working in the background.
    func selectGroup(_ id: String) {
        cancelStream()
        selectedAgentID = ""
        snapshot = nil
        stopGroupStream()
        selectionVersion += 1
        let version = selectionVersion
        selectedGroupID = id
        route = .group(id)
        groupSnapshot = nil
        messages = delivery.messages(botID: Self.groupKey(id))
        hasMore = false
        oldestEntryID = ""
        loadingOlder = false
        replyTo = nil
        draft = ""
        attachments = []
        sending = false
        draftRequestID = ""
        request { client in
            let snapshot = try await client.groupChat(id)
            return { [self] in
                guard selectionVersion == version, selectedGroupID == id else { return }
                applyGroupSnapshot(snapshot)
                hasMore = snapshot.hasMore
                oldestEntryID = snapshot.oldestEntryId ?? ""
                groupStreamTask = Task { await streamGroup(client: client, id: id, version: version) }
            }
        }
    }

    /// Closes the open group chat, if any, so a bot chat or panel can take its place.
    func leaveGroup() {
        stopGroupStream()
        selectedGroupID = ""
        groupSnapshot = nil
    }

    func stopGroupStream() {
        groupStreamTask?.cancel()
        groupStreamTask = nil
    }

    /// Keeps older pages the owner already loaded; snapshots only carry the newest page.
    func applyGroupSnapshot(_ incoming: GroupChatSnapshot) {
        let key = Self.groupKey(selectedGroupID)
        delivery.acknowledge(botID: key, requestIDs: Set(incoming.messages.compactMap(\.requestId)))
        messages = mergeMessages(messages.filter { $0.deliveryState == .confirmed }, incoming.messages)
        messages.append(contentsOf: delivery.messages(botID: key))
        if let index = groupChats.firstIndex(where: { $0.id == incoming.groupChat.id }),
            !pendingMutations.contains("group:\(incoming.groupChat.id)") {
            groupChats[index] = incoming.groupChat
        }
        var snapshot = incoming
        snapshot.messages = []
        groupSnapshot = snapshot
    }

    private func streamGroup(client: APIClient, id: String, version: Int) async {
        var backoff = Duration.milliseconds(500)
        while !Task.isCancelled {
            do {
                try await client.groupChatEvents(id) { payload in
                    guard let snapshot = try? JSONDecoder().decode(GroupChatSnapshot.self, from: Data(payload.utf8))
                    else { return }
                    await MainActor.run {
                        guard self.selectionVersion == version, self.selectedGroupID == id, !Task.isCancelled else {
                            return
                        }
                        self.applyGroupSnapshot(snapshot)
                        self.streamStatus = ""
                    }
                }
            } catch {
                if Task.isCancelled || selectionVersion != version { return }
                if let apiError = error as? APIError, apiError.statusCode == 401 {
                    errorText = friendlyError(error)
                    streamStatus = "Disconnected"
                    return
                }
                if let apiError = error as? APIError, apiError.statusCode == 404 {
                    leaveGroup()
                    route = nil
                    loadGroupChats()
                    return
                }
                streamStatus = "Reconnecting…"
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(8))
        }
    }

    func reconnectGroupStream() {
        guard let client, groupStreamTask != nil, !selectedGroupID.isEmpty else { return }
        groupStreamTask?.cancel()
        let id = selectedGroupID
        let version = selectionVersion
        groupStreamTask = Task { await streamGroup(client: client, id: id, version: version) }
    }

    @discardableResult
    func sendGroupMessage() -> Task<Void, Never>? {
        guard groupSnapshot != nil, let client else { return nil }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !content.isEmpty || !files.isEmpty else { return nil }
        let id = selectedGroupID
        let key = Self.groupKey(id)
        let reply = replyTo?.entryId ?? ""
        draftRequestID = newRequestID()
        let requestID = draftRequestID
        let record = BotChatDelivery.Send(
            content: content, replyTo: reply, attachments: files, replyPreview: replyTo?.text.nilIfEmpty)
        failedDraft = content
        sending = true
        draft = ""
        attachments = []
        messages.append(delivery.stage(record, botID: key, requestID: requestID))
        replyTo = nil
        let generation = generation
        let version = selectionVersion
        return Task {
            do {
                try await client.sendGroupMessage(
                    id, content: content, requestID: requestID, replyTo: reply, attachments: files.map(\.outgoing))
                guard self.generation == generation else { return }
                delivery.accepted(botID: key, requestID: requestID)
                guard selectionVersion == version, selectedGroupID == id else { return }
                sending = false
                draftRequestID = ""
                failedDraft = ""
            } catch {
                guard self.generation == generation else { return }
                guard failGroupMessage(error, id: id, requestID: requestID, version: version) else { return }
                if selectionVersion == version, selectedGroupID == id, draft.isEmpty, attachments.isEmpty {
                    draft = content
                    attachments = files
                }
            }
        }
    }

    /// Re-sends a failed group message with its original idempotency key and attachments.
    func retryGroupMessage(_ message: Message) {
        let id = selectedGroupID
        let key = Self.groupKey(id)
        guard message.deliveryState == .failed, let requestID = message.requestId, let client,
            let record = delivery.beginRetry(botID: key, requestID: requestID)
        else { return }
        if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
            messages[visible].deliveryState = .sending
        }
        sending = true
        let generation = generation
        let version = selectionVersion
        Task {
            do {
                try await client.sendGroupMessage(
                    id, content: record.content, requestID: requestID, replyTo: record.replyTo,
                    attachments: record.attachments.map(\.outgoing))
                guard self.generation == generation else { return }
                delivery.accepted(botID: key, requestID: requestID)
                if selectionVersion == version, selectedGroupID == id { sending = false }
            } catch {
                guard self.generation == generation else { return }
                _ = failGroupMessage(error, id: id, requestID: requestID, version: version)
            }
        }
    }

    private func failGroupMessage(_ error: Error, id: String, requestID: String, version: Int) -> Bool {
        let current = selectionVersion == version && selectedGroupID == id
        if current { sending = false }
        guard delivery.fail(botID: Self.groupKey(id), requestID: requestID) else { return false }
        if current {
            errorText = "Message was not confirmed: " + friendlyError(error)
            if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
                messages[visible].deliveryState = .failed
            }
        }
        return true
    }

    /// Ends every running bot turn in the open group; the stream reports when they have stopped.
    func stopGroup() {
        let id = selectedGroupID
        optimisticMutation(
            key: "stop:\(id)",
            update: { [self] in showNotice("Stopping…") }, rollback: {},
            work: { client in
                try await client.stopGroupChat(id)
                return nil
            })
    }

    func loadOlderGroupMessages() {
        guard !loadingOlder, hasMore, !oldestEntryID.isEmpty else { return }
        let id = selectedGroupID
        let before = oldestEntryID
        let version = selectionVersion
        loadingOlder = true
        request { client in
            do {
                let page = try await client.groupChatHistory(id, before: before, limit: 100)
                return { [self] in
                    guard selectionVersion == version, selectedGroupID == id else { return }
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

    // MARK: Creating and editing groups

    func createGroup() {
        groupDraft = GroupDraft(memberIDs: [])
    }

    func editGroup(_ group: GroupChat) {
        groupDraft = GroupDraft(groupID: group.id, name: group.name, memberIDs: group.memberIds)
    }

    /// Shows a new group at once under a provisional ID and swaps in the server's when it confirms.
    func saveGroup(_ draft: GroupDraft) {
        guard draft.isValid else { return }
        groupDraft = nil
        if let id = draft.groupID {
            updateGroup(id, draft: draft)
        } else {
            addGroup(draft)
        }
    }

    private func addGroup(_ draft: GroupDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = draft.memberIDs
        let provisional = "local:" + newRequestID()
        let now = ISO8601DateFormatter().string(from: Date())
        let routeAtStart = route
        optimisticMutation(
            key: "group:\(provisional)",
            update: { [self] in
                groupChats.append(GroupChat(
                    id: provisional, name: name, memberIds: members, createdAt: now, updatedAt: now))
            },
            rollback: { [self] in
                groupChats.removeAll { $0.id == provisional }
                if groupDraft == nil { groupDraft = draft }
            },
            work: { client in
                let created = try await client.createGroupChat(name: name, memberIDs: members)
                return { [self] in
                    groupChats.removeAll { $0.id == provisional || $0.id == created.id }
                    groupChats.append(created)
                    // Open the new group only if the owner is still where they were; a late response must not
                    // take them away from a chat they moved to meanwhile, or clear what they typed there.
                    if route == routeAtStart { selectGroup(created.id) }
                }
            })
    }

    private func updateGroup(_ id: String, draft: GroupDraft) {
        guard let previous = groupChats.first(where: { $0.id == id }) else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = draft.memberIDs
        optimisticMutation(
            key: "group:\(id)",
            update: { [self] in
                if let index = groupChats.firstIndex(where: { $0.id == id }) {
                    groupChats[index].name = name
                    groupChats[index].memberIds = members
                }
            },
            rollback: { [self] in
                if let index = groupChats.firstIndex(where: { $0.id == id }) { groupChats[index] = previous }
                if groupDraft == nil { groupDraft = draft }
            },
            work: { client in
                let updated = try await client.updateGroupChat(id, name: name, memberIDs: members)
                return { [self] in
                    if let index = groupChats.firstIndex(where: { $0.id == id }) { groupChats[index] = updated }
                }
            })
    }

    func deleteGroup(_ id: String) {
        guard let index = groupChats.firstIndex(where: { $0.id == id }) else { return }
        let removed = groupChats[index]
        let wasOpen = selectedGroupID == id
        optimisticMutation(
            key: "group:\(id)",
            update: { [self] in
                groupChats.removeAll { $0.id == id }
                if wasOpen {
                    leaveGroup()
                    route = nil
                    messages = []
                }
            },
            rollback: { [self] in
                if !groupChats.contains(where: { $0.id == id }) {
                    groupChats.insert(removed, at: min(index, groupChats.count))
                }
            },
            work: { client in
                try await client.deleteGroupChat(id)
                return nil
            })
    }

    /// A tapped group notification opens its group, looking it up again if the list is stale.
    func openNotificationGroup(_ id: String) {
        guard !groupChats.contains(where: { $0.id == id }) else {
            selectGroup(id)
            return
        }
        request { client in
            let groups = try await client.groupChats()
            return { [self] in
                guard groups.contains(where: { $0.id == id }) else {
                    errorText = "The group chat for this notification no longer exists."
                    return
                }
                if pendingMutations.isEmpty { groupChats = groups }
                selectGroup(id)
            }
        }
    }
}
