import Foundation

public struct BotChatDelivery {
  public struct Send: Sendable {
    public var content: String
    public var replyTo: String
    public var attachments: [PendingAttachment]
    public var replyPreview: String?

    public init(
      content: String, replyTo: String, attachments: [PendingAttachment], replyPreview: String? = nil
    ) {
      self.content = content
      self.replyTo = replyTo
      self.attachments = attachments
      self.replyPreview = replyPreview
    }
  }

  private struct Pending {
    var send: Send
    var message: Message
  }

  private struct Chat {
    var pending: [Pending] = []
    var preview: (requestID: String, text: String)?
  }

  private var chats: [String: Chat] = [:]

  public init() {}

  public mutating func stage(_ send: Send, botID: String, requestID: String) -> Message {
    let message = Message(
      id: "local:\(requestID)", role: "user", content: .string(send.content),
      replyTo: send.replyTo.nilIfEmpty, replyPreview: send.replyPreview,
      timestamp: Int64(Date().timeIntervalSince1970 * 1000),
      attachments: send.attachments.map {
        AttachmentInfo(
          name: $0.name, mimeType: $0.mimeType, size: $0.data.count, kind: $0.isImage ? "image" : "file")
      },
      requestId: requestID, deliveryState: .sending
    )
    chats[botID, default: Chat()].pending.append(Pending(send: send, message: message))
    let preview = send.content.nilIfEmpty ?? send.attachments.first.map { "Attachment: \($0.name)" } ?? ""
    chats[botID]?.preview = (requestID, preview)
    return message
  }

  public mutating func beginRetry(botID: String, requestID: String) -> Send? {
    guard let index = pendingIndex(botID: botID, requestID: requestID) else { return nil }
    chats[botID]?.pending[index].message.deliveryState = .sending
    return chats[botID]?.pending[index].send
  }

  // HTTP acceptance is not transcript confirmation.
  public mutating func accepted(botID: String, requestID: String) {
    clearPreview(botID: botID, requestID: requestID)
  }

  public mutating func acknowledge(botID: String, requestIDs: Set<String>) {
    chats[botID]?.pending.removeAll { requestIDs.contains($0.message.requestId ?? "") }
    if let preview = chats[botID]?.preview, requestIDs.contains(preview.requestID) {
      chats[botID]?.preview = nil
    }
  }

  public mutating func fail(botID: String, requestID: String) -> Bool {
    guard let index = pendingIndex(botID: botID, requestID: requestID) else { return false }
    chats[botID]?.pending[index].message.deliveryState = .failed
    clearPreview(botID: botID, requestID: requestID)
    return true
  }

  public mutating func reset() {
    chats.removeAll()
  }

  public func messages(botID: String) -> [Message] {
    chats[botID]?.pending.map(\.message) ?? []
  }

  public func preview(botID: String) -> String? {
    chats[botID]?.preview?.text
  }

  public func imageData(botID: String, requestID: String, index: Int) -> Data? {
    guard let pending = pendingIndex(botID: botID, requestID: requestID),
      let files = chats[botID]?.pending[pending].send.attachments,
      files.indices.contains(index), files[index].isImage
    else { return nil }
    return files[index].data
  }

  private func pendingIndex(botID: String, requestID: String) -> Int? {
    chats[botID]?.pending.firstIndex { $0.message.requestId == requestID }
  }

  private mutating func clearPreview(botID: String, requestID: String) {
    if chats[botID]?.preview?.requestID == requestID { chats[botID]?.preview = nil }
  }
}
