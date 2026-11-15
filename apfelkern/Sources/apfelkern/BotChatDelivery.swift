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
    /// Server file IDs for the attachments an attempt already uploaded, so a retry uploads only the rest.
    var uploaded: [UUID: String] = [:]
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
        AttachmentInfo(name: $0.name, mimeType: $0.mimeType, size: $0.data.count)
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

  /// Marks a send failed. When the server rejected it because a file it carries left the library, the next retry
  /// uploads every attachment again from the bytes the send kept; other failures keep the uploads.
  public mutating func fail(botID: String, requestID: String, error: Error? = nil) -> Bool {
    guard let index = pendingIndex(botID: botID, requestID: requestID) else { return false }
    chats[botID]?.pending[index].message.deliveryState = .failed
    if let error, Self.rejectsFiles(error) { chats[botID]?.pending[index].uploaded = [:] }
    clearPreview(botID: botID, requestID: requestID)
    return true
  }

  /// The file ID an earlier attempt of this send uploaded for one of its attachments.
  public func uploadedFile(_ attachment: UUID, botID: String, requestID: String) -> String? {
    pendingIndex(botID: botID, requestID: requestID).flatMap { chats[botID]?.pending[$0].uploaded[attachment] }
  }

  /// Keeps an upload for the send's retries; false once the send is no longer pending, so its delivery stops.
  public mutating func recordUpload(_ fileID: String, for attachment: UUID, botID: String, requestID: String)
    -> Bool {
    guard let index = pendingIndex(botID: botID, requestID: requestID) else { return false }
    chats[botID]?.pending[index].uploaded[attachment] = fileID
    return true
  }

  public func isPending(botID: String, requestID: String) -> Bool {
    pendingIndex(botID: botID, requestID: requestID) != nil
  }

  /// The server's answer to a message that lists a file deleted from, or never in, the chat's library.
  static func rejectsFiles(_ error: Error) -> Bool {
    guard let error = error as? APIError, error.statusCode == 400 else { return false }
    let message = friendlyError(error)
    return message.contains("File not found in this library") || message.contains(" was deleted from the library")
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
