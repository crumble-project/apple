import Foundation

/// The files the server reported deleted in the chats one connection has open. A transcript can list a file in several
/// messages while only the newest page says it is gone, so every reference in the chat follows the deletion.
public struct DeletedFiles: Sendable {
  private var keys: Set<String> = []

  public init() {}

  /// Remembers the files `messages` report deleted and returns them with every other reference to those files
  /// deleted too.
  public mutating func reconcile(_ messages: [Message], chat: String) -> [Message] {
    for message in messages {
      for file in message.attachments ?? [] where file.deleted && !file.id.isEmpty {
        keys.insert(Self.key(file.id, chat: chat))
      }
    }
    guard !keys.isEmpty else { return messages }
    return messages.map { message in
      guard let files = message.attachments,
        files.contains(where: { !$0.deleted && contains($0.id, chat: chat) })
      else { return message }
      var message = message
      message.attachments = files.map { !$0.deleted && contains($0.id, chat: chat) ? .deleted($0.id) : $0 }
      return message
    }
  }

  public func contains(_ fileID: String, chat: String) -> Bool {
    !fileID.isEmpty && keys.contains(Self.key(fileID, chat: chat))
  }

  public mutating func removeAll() {
    keys.removeAll()
  }

  private static func key(_ fileID: String, chat: String) -> String { chat + "/" + fileID }
}
