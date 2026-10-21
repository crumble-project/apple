import Foundation

/// An emoji a bot reacted with instead of replying, carried by a successful `react` tool result.
public enum Reaction {
  public static let toolName = "react"

  /// The emoji of a successful `react` tool result; nil for other messages.
  public static func emoji(of message: Message) -> String? {
    guard message.role == "toolResult", message.toolName == toolName, message.isError != true else { return nil }
    return message.toolDetails?["emoji"]?.stringValue
  }

  /// Reaction emoji keyed by the ID of the message they answer: the latest owner-side input before each one.
  public static func byMessage(_ messages: [Message]) -> [String: [String]] {
    var reactions: [String: [String]] = [:]
    var input: String?
    for message in messages {
      if message.role == "user" {
        input = message.id
      } else if let input, let emoji = emoji(of: message) {
        reactions[input, default: []].append(emoji)
      }
    }
    return reactions
  }

  /// An emoji and who reacted with it, for group chats where several bots may react to one message.
  public struct Mark: Hashable, Sendable {
    public var emoji: String
    public var from: String?

    public init(emoji: String, from: String? = nil) {
      self.emoji = emoji
      self.from = from
    }
  }

  /// Group chat reactions keyed by the ID of the message they answer, which each reaction names in `replyTo`.
  public static func byReplyTarget(_ messages: [Message]) -> [String: [Mark]] {
    let ids = Dictionary(
      messages.compactMap { message in message.entryId.map { ($0, message.id) } },
      uniquingKeysWith: { first, _ in first })
    var reactions: [String: [Mark]] = [:]
    for message in messages {
      guard let emoji = emoji(of: message), let target = message.replyTo, let id = ids[target] else { continue }
      reactions[id, default: []].append(Mark(emoji: emoji, from: message.origin?.name))
    }
    return reactions
  }
}
