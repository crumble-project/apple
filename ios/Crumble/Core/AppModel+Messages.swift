import apfelkern
import Foundation
import UIKit

extension AppModel {
  private struct SendContext {
    let id: String
    let requestID: String
    let generation: Int
    let selection: Int
  }

  @discardableResult
  func sendMessage() -> Task<Void, Never>? {
    guard snapshot != nil, let client else { return nil }
    let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let files = attachments
    guard !content.isEmpty || !files.isEmpty else { return nil }
    let id = selectedAgentID
    let reply = replyTo?.entryId ?? ""
    draftRequestID = newRequestID()
    let requestID = draftRequestID
    let record = BotChatDelivery.Send(
      content: content, replyTo: reply, attachments: files, replyPreview: replyTo?.text.nilIfEmpty)
    stageMessage(record, id: id, requestID: requestID)
    let context = SendContext(
      id: id, requestID: requestID, generation: generation, selection: selectionVersion)
    return Task {
      await performSend(client: client, context: context, record: record, restoringDraft: true)
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
    let context = SendContext(
      id: selectedAgentID, requestID: requestID, generation: generation, selection: selectionVersion)
    Task {
      await performSend(client: client, context: context, record: record, restoringDraft: false)
    }
  }

  private func stageMessage(_ record: BotChatDelivery.Send, id: String, requestID: String) {
    failedDraft = record.content
    failedReplyTo = record.replyTo
    failedAttachments = record.attachments.map(\.id)
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

  private func performSend(
    client: APIClient, context: SendContext, record: BotChatDelivery.Send, restoringDraft: Bool
  ) async {
    let id = context.id
    let requestID = context.requestID
    do {
      try await client.sendChatMessage(
        id, content: record.content, requestID: requestID, replyTo: record.replyTo,
        attachments: record.attachments.map(\.outgoing))
      guard generation == context.generation else { return }
      delivery.accepted(botID: id, requestID: requestID)
      guard selectionVersion == context.selection, selectedAgentID == id else { return }
      sending = false
      if restoringDraft {
        draftRequestID = ""
        failedDraft = ""
        failedReplyTo = ""
        failedAttachments = []
      }
    } catch {
      guard generation == context.generation else { return }
      guard failMessage(error, id: id, requestID: requestID, version: context.selection) else { return }
      if restoringDraft, selectionVersion == context.selection, selectedAgentID == id,
        draft.isEmpty, attachments.isEmpty {
        draft = record.content
        attachments = record.attachments
      }
    }
  }

  private func failMessage(_ error: Error, id: String, requestID: String, version: Int) -> Bool {
    if selectionVersion == version, selectedAgentID == id { sending = false }
    guard delivery.fail(botID: id, requestID: requestID) else { return false }
    if selectionVersion == version, selectedAgentID == id {
      errorText = "Message was not confirmed: " + friendlyError(error)
      if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
        messages[visible].deliveryState = .failed
      }
    }
    return true
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

  func attachmentImage(entryID: String, index: Int) -> UIImage? {
    attachmentImages["\(entryID)/\(index)"]
  }

  func attachmentImage(message: Message, index: Int) -> UIImage? {
    if let entryID = message.entryId { return attachmentImage(entryID: entryID, index: index) }
    guard let requestID = message.requestId,
      let data = delivery.imageData(botID: selectedAgentID, requestID: requestID, index: index)
    else { return nil }
    return UIImage(data: data)
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
