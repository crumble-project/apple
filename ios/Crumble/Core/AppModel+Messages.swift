import Foundation
import UIKit

extension AppModel {
  private struct SendContext {
    let id: String
    let requestID: String
    let generation: Int
    let selection: Int
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
    enqueueMessage(id: id, requestID: requestID, content: content, reply: reply, files: files)
    // Clear the captured reply immediately; a later composer selection must survive this send.
    replyTo = nil
    let generation = generation
    let version = selectionVersion
    Task {
      await performSend(
        client: client,
        context: SendContext(id: id, requestID: requestID, generation: generation, selection: version),
        record: PendingSend(content: content, replyTo: reply, attachments: files), restoringDraft: true)
    }
  }

  /// Re-sends a failed optimistic row with its original idempotency key and attachments.
  func retryMessage(_ message: Message) {
    guard message.deliveryState == .failed, let requestID = message.requestId,
      let record = pendingSends[selectedAgentID]?[requestID], let client
    else { return }
    guard
      let index = pendingMessages[selectedAgentID]?.firstIndex(where: { $0.requestId == requestID })
    else { return }
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
      await performSend(
        client: client,
        context: SendContext(id: id, requestID: requestID, generation: generation, selection: version),
        record: record, restoringDraft: false)
    }
  }

  private func enqueueMessage(
    id: String, requestID: String, content: String, reply: String, files: [PendingAttachment]
  ) {
    let optimistic = Message(
      id: "local:\(requestID)", role: "user", content: .string(content), replyTo: reply.nilIfEmpty,
      replyPreview: replyTo?.text.nilIfEmpty, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
      attachments: files.map {
        AttachmentInfo(
          name: $0.name, mimeType: $0.mimeType, size: $0.data.count,
          kind: $0.isImage ? "image" : "file")
      },
      requestId: requestID, deliveryState: .sending
    )
    pendingMessages[id, default: []].append(optimistic)
    pendingSends[id, default: [:]][requestID] = PendingSend(
      content: content, replyTo: reply, attachments: files)
    let preview = content.nilIfEmpty ?? files.first.map { "Attachment: \($0.name)" } ?? ""
    pendingPreviews[id] = (requestID, preview)
    if let agentIndex = agents.firstIndex(where: { $0.id == id }) {
      agents[agentIndex].lastMessage = preview
    }
    if selectedAgentID == id { messages.append(optimistic) }
  }

  private func performSend(
    client: APIClient, context: SendContext, record: PendingSend, restoringDraft: Bool
  ) async {
    let id = context.id
    let requestID = context.requestID
    let generation = context.generation
    let version = context.selection
    do {
      try await client.sendChatMessage(
        id, content: record.content, requestID: requestID, replyTo: record.replyTo,
        attachments: record.attachments.map(\.outgoing))
      guard self.generation == generation else { return }
      if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
      guard self.selectionVersion == version, selectedAgentID == id else { return }
      sending = false
      if restoringDraft {
        draftRequestID = ""
        failedDraft = ""
        failedReplyTo = ""
        failedAttachments = []
      }
    } catch {
      guard self.generation == generation else { return }
      failMessage(id: id, requestID: requestID, version: version, error: error)
      if restoringDraft, self.selectionVersion == version, selectedAgentID == id,
        pendingMessages[id]?.contains(where: { $0.requestId == requestID }) == true,
        draft.isEmpty, attachments.isEmpty {
        draft = record.content
        attachments = record.attachments
      }
    }
  }

  private func failMessage(id: String, requestID: String, version: Int, error: Error) {
    let visible = selectionVersion == version && selectedAgentID == id
    if visible { sending = false }
    guard pendingMessages[id]?.contains(where: { $0.requestId == requestID }) == true else { return }
    if visible { errorText = "Message was not confirmed: " + friendlyError(error) }
    if let index = pendingMessages[id]?.firstIndex(where: { $0.requestId == requestID }) {
      pendingMessages[id]?[index].deliveryState = .failed
      if pendingPreviews[id]?.requestID == requestID { pendingPreviews[id] = nil }
      if visible, let index = messages.firstIndex(where: { $0.requestId == requestID }) {
        messages[index].deliveryState = .failed
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

  func attachmentImage(entryID: String, index: Int) -> UIImage? {
    attachmentImages["\(entryID)/\(index)"]
  }

  func attachmentImage(message: Message, index: Int) -> UIImage? {
    if let entryID = message.entryId { return attachmentImage(entryID: entryID, index: index) }
    guard let requestID = message.requestId,
      let files = pendingSends[selectedAgentID]?[requestID]?.attachments,
      files.indices.contains(index), files[index].isImage
    else { return nil }
    return UIImage(data: files[index].data)
  }

  func loadAttachmentImage(entryID: String, index: Int) async {
    let key = "\(entryID)/\(index)"
    guard attachmentImages[key] == nil, let client else { return }
    guard !entryID.hasPrefix("local:") else { return }
    let agent = selectedAgentID
    guard let data = try? await client.attachment(agent, entryID: entryID, index: index),
      let image = UIImage(data: data)
    else { return }
    cacheAttachmentImage(image, key: key)
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
