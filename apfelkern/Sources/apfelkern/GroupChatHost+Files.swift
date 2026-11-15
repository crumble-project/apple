import Foundation

/// Attachments in bot and group chats: uploads before a send, and downloads by file ID for the open chat.
extension GroupChatHost {
  /// The file IDs a pending bot or group send carries, uploading only the attachments an earlier attempt did not.
  /// Nil once the send no longer belongs to this connection or is no longer pending, so a late upload neither sends
  /// nor changes newer state. Uploads stay with their send, so no other chat or connection reuses them.
  public func uploadFiles(
    _ send: BotChatDelivery.Send, chat: String, requestID: String, generation: Int,
    upload: (PendingAttachment) async throws -> String
  ) async throws -> [String]? {
    var fileIDs: [String] = []
    for file in send.attachments {
      guard self.generation == generation, delivery.isPending(botID: chat, requestID: requestID) else { return nil }
      if let fileID = delivery.uploadedFile(file.id, botID: chat, requestID: requestID) {
        fileIDs.append(fileID)
        continue
      }
      let fileID = try await upload(file)
      guard self.generation == generation,
        delivery.recordUpload(fileID, for: file.id, botID: chat, requestID: requestID)
      else { return nil }
      fileIDs.append(fileID)
    }
    return self.generation == generation ? fileIDs : nil
  }

  /// The image cache key for an attachment in the open chat: its file ID, or for a bot entry without files, such as
  /// a desktop screenshot, the entry and index. Nil when there is nothing to fetch, such as for a deleted file.
  public func attachmentKey(_ message: Message, index: Int) -> String? {
    guard let entryID = message.entryId, !entryID.hasPrefix("local:") else { return nil }
    let chat = conversationKey
    guard let files = message.attachments else {
      return selectedGroupID.isEmpty ? "\(chat)/\(entryID)/\(index)" : nil
    }
    guard files.indices.contains(index) else { return nil }
    let file = files[index]
    guard !file.id.isEmpty, !file.deleted, !deletedFiles.contains(file.id, chat: chat) else { return nil }
    return "\(chat)/\(file.id)"
  }

  /// Downloads an attachment the open chat shows, by its file ID. Nil when `cached` already holds it, or when it
  /// is no longer shown by the time it arrives: its file was deleted, or the chat or connection changed.
  public func downloadAttachment(entryID: String, index: Int, cached: (String) -> Bool) async
    -> (key: String, data: Data)? {
    guard let client, let message = messages.first(where: { $0.entryId == entryID }),
      let key = attachmentKey(message, index: index), !cached(key)
    else { return nil }
    let generation = generation
    let agentID = selectedAgentID
    let groupID = selectedGroupID
    let fileID = message.attachments.map { $0[index].id }
    let data: Data?
    if let fileID {
      data = groupID.isEmpty
        ? try? await client.file(agentID, fileID: fileID) : try? await client.groupFile(groupID, fileID: fileID)
    } else {
      data = try? await client.attachment(agentID, entryID: entryID, index: index)
    }
    guard let data, !data.isEmpty, self.generation == generation,
      let current = messages.first(where: { $0.entryId == entryID }), attachmentKey(current, index: index) == key
    else { return nil }
    return (key, data)
  }
}
