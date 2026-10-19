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
}
