import Foundation

extension Message {
  /// A successful `desktop_screenshot` result; its image is the entry's first attachment.
  public var isDesktopScreenshot: Bool {
    role == "toolResult" && toolName == "desktop_screenshot" && isError != true
  }
}

/// A job's failure as the chat reports it, with the job to open.
public struct JobFailure: Hashable, Sendable {
  public static let messageKind = "job-failure"

  public var kind: JobKind
  public var name: String
  public var text: String

  public init?(message: Message) {
    guard message.kind == Self.messageKind,
      let kind = JobKind.allCases.first(where: { $0.originKind == message.origin?.kind }),
      let name = message.origin?.name
    else { return nil }
    self.kind = kind
    self.name = name
    text = message.text
  }

  /// The server writes a sentence fragment; the card starts it with a capital.
  public var title: String { text.prefix(1).uppercased() + text.dropFirst() }
}

/// The title of the collapsed row that stands in for an automated turn's prompt; nil for other messages.
public func noticeTitle(_ message: Message) -> String? {
  guard message.role == "user", let origin = message.origin else { return nil }
  let name = origin.name ?? ""
  switch origin.kind {
  case "bot_request": return "Bot request"
  case "task", "credential", "bot": return messageLabel(message)
  case "script": return "Script automation · \(name)"
  case "event": return "Automation · \(name), event from \(origin.source ?? "a deleted source")"
  default: return nil
  }
}

/// A message gateway's name for "Sent from"; a gateway this client doesn't know keeps its ID.
public func gatewayLabel(_ id: String) -> String {
  id == "discord" ? "Discord" : id
}

/// Keeps the conversation itself: owner and agent text, context events, and the cards tools leave,
/// not thinking, tool calls, or other tool results.
public func shownInChat(_ message: Message) -> Bool {
  switch message.role {
  case "toolResult":
    return DisplayComponent(message: message) != nil || message.isDesktopScreenshot
      || Job(message: message) != nil || BotRequest(message: message) != nil
      || BotSecretAsk(message: message) != nil
  case "user":
    guard !JobKind.isReport(message) else { return false }
    return !message.text.isEmpty || !(message.attachments ?? []).isEmpty
  case "event":
    return !message.text.isEmpty
  case "assistant":
    guard case .array(let blocks)? = message.blocks else { return !contentText(message.blocks).isEmpty }
    return blocks.contains {
      $0["type"]?.stringValue == "text"
        && !($0["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  default:
    return false
  }
}
