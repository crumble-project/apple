import apfelkern
import Foundation

extension AppModel {
    @discardableResult
    func sendMessage() -> Task<Void, Never>? {
        guard snapshot != nil, let client else { return nil }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !content.isEmpty || !files.isEmpty else { return nil }
        let id = selectedAgentID
        let reply = replyTo?.entryId ?? ""
        // Every explicit send gets its own idempotency key. Failed rows are retried through
        // retryMessage, so two identical messages must remain distinct.
        draftRequestID = newRequestID()
        let requestID = draftRequestID
        let record = BotChatDelivery.Send(
            content: content, replyTo: reply, attachments: files, replyPreview: replyTo?.text.nilIfEmpty)
        stageMessage(record, id: id, requestID: requestID)
        let generation = generation
        let version = selectionVersion
        return Task {
            do {
                try await client.sendChatMessage(
                    id, content: content, requestID: requestID, replyTo: reply,
                    attachments: files.map(\.outgoing))
                guard self.generation == generation else { return }
                delivery.accepted(botID: id, requestID: requestID)
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
        guard message.deliveryState == .failed, let requestID = message.requestId, let client,
            let record = delivery.beginRetry(botID: selectedAgentID, requestID: requestID)
        else { return }
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
                delivery.accepted(botID: id, requestID: requestID)
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

    private func stageMessage(_ record: BotChatDelivery.Send, id: String, requestID: String) {
        let content = record.content
        let files = record.attachments
        failedDraft = content
        failedReplyTo = record.replyTo
        failedAttachments = files.map(\.id)
        sending = true
        draft = ""
        attachments = []
        let optimistic = delivery.stage(record, botID: id, requestID: requestID)
        if let agentIndex = agents.firstIndex(where: { $0.id == id }) {
            agents[agentIndex].lastMessage = delivery.preview(botID: id) ?? ""
        }
        if selectedAgentID == id { messages.append(optimistic) }
        // Clear the captured reply immediately; a later composer selection must survive this send.
        replyTo = nil
    }

    private func failMessage(_ error: Error, id: String, requestID: String, version: Int) -> Bool {
        if self.selectionVersion == version, selectedAgentID == id { sending = false }
        guard delivery.fail(botID: id, requestID: requestID) else { return false }
        if self.selectionVersion == version, selectedAgentID == id {
            errorText = "Message was not confirmed: " + friendlyError(error)
            if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
                messages[visible].deliveryState = .failed
            }
        }
        return true
    }
}
