import Foundation

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
        let record = PendingSend(content: content, replyTo: reply, attachments: files)
        stageMessage(record, id: id, requestID: requestID)
        let generation = generation
        let version = selectionVersion
        Task {
            do {
                try await client.sendChatMessage(
                    id, content: content, requestID: requestID, replyTo: reply,
                    attachments: files.map(\.outgoing))
                guard self.generation == generation else { return }
                if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
                guard self.generation == generation, self.selectionVersion == version, selectedAgentID == id else {
                    return
                }
                sending = false
                draftRequestID = ""
                failedDraft = ""
                failedReplyTo = ""
                failedAttachments = []
            } catch {
                guard self.generation == generation else { return }
                guard failMessage(error, id: id, requestID: requestID, version: version) else { return }
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
            let record = pendingSends[selectedAgentID]?[requestID], let client
        else { return }
        guard let index = pendingMessages[selectedAgentID]?.firstIndex(where: { $0.requestId == requestID }) else {
            return
        }
        pendingMessages[selectedAgentID]?[index].deliveryState = .sending
        if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
            messages[visible].deliveryState = .sending
        }
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
                try await client.sendChatMessage(
                    id, content: record.content, requestID: requestID,
                    replyTo: record.replyTo, attachments: record.attachments.map(\.outgoing))
                guard self.generation == generation else { return }
                if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
                guard self.generation == generation, self.selectionVersion == version, selectedAgentID == id else {
                    return
                }
                sending = false
            } catch {
                guard self.generation == generation else { return }
                _ = failMessage(error, id: id, requestID: requestID, version: version)
            }
        }
    }

    private func stageMessage(_ record: PendingSend, id: String, requestID: String) {
        let content = record.content
        let files = record.attachments
        let reply = record.replyTo
        failedDraft = content
        failedReplyTo = reply
        failedAttachments = files.map(\.id)
        sending = true
        draft = ""
        attachments = []
        let optimistic = optimisticMessage(record, requestID: requestID)
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
    }

    private func optimisticMessage(_ record: PendingSend, requestID: String) -> Message {
        let content = record.content
        let files = record.attachments
        let reply = record.replyTo
        return Message(
            id: "local:\(requestID)", role: "user", content: .string(content), replyTo: reply.nilIfEmpty,
            replyPreview: replyTo?.text.nilIfEmpty, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            attachments: files.map {
                AttachmentInfo(
                    name: $0.name, mimeType: $0.mimeType, size: $0.data.count, kind: $0.isImage ? "image" : "file")
            },
            requestId: requestID, deliveryState: .sending
        )
    }

    private func failMessage(_ error: Error, id: String, requestID: String, version: Int) -> Bool {
        if self.selectionVersion == version, selectedAgentID == id { sending = false }
        guard pendingMessages[id]?.contains(where: { $0.requestId == requestID }) == true else { return false }
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
        return true
    }
}
