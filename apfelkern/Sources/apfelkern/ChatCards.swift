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

/// A voice gateway call in the chat: its start or end, or the notice that its end woke the bot.
public struct CallMarker: Hashable, Sendable {
  public static let startedKind = "call-started"
  public static let endedKind = "call-ended"
  public static let originKind = "call"

  /// The bot placed the call, so its start reads "{bot} called you" over the greeting it spoke.
  public var outbound: Bool
  public var ended: Bool
  public var text: String

  public init?(message: Message) {
    if message.role == "user", message.origin?.kind == Self.originKind {
      outbound = false
      ended = true
    } else if message.role == "event", let call = message.call,
      [Self.startedKind, Self.endedKind].contains(message.kind) {
      outbound = call.direction == .outbound
      ended = message.kind == Self.endedKind
    } else {
      return nil
    }
    text = message.text
  }

  public func title(botName: String) -> String {
    if ended { return text }
    return outbound ? "\(botName) called you" : "Call started"
  }

  /// The greeting the bot spoke on a call it placed.
  public var quote: String? { !ended && outbound ? text.nilIfEmpty : nil }
}

/// The title of the collapsed row that stands in for an automated turn's prompt; nil for other messages.
public func noticeTitle(_ message: Message) -> String? {
  guard message.role == "user", let origin = message.origin else { return nil }
  let name = origin.name ?? ""
  switch origin.kind {
  case "bot_request": return "Bot request"
  case CallRequest.noticeOriginKind: return "Call request"
  case CallMarker.originKind: return "Call"
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

/// The voice gateway's `via` on a spoken message.
public let voiceGatewayID = "voice"

/// The line under an owner message that came through a gateway: "Sent from Discord" or, for a spoken message,
/// "Spoken on a call".
public func gatewayOrigin(_ id: String) -> String {
  id == voiceGatewayID ? "Spoken on a call" : "Sent from \(gatewayLabel(id))"
}

/// Keeps the conversation itself: owner and agent text, context events, and the cards tools leave,
/// not thinking, tool calls, or other tool results.
public func shownInChat(_ message: Message) -> Bool {
  switch message.role {
  case "toolResult":
    return DisplayComponent(message: message) != nil || message.isDesktopScreenshot
      || Job(message: message) != nil || BotRequest(message: message) != nil
      || CallRequest(message: message) != nil
      || BotSecretAsk(message: message) != nil
  case "user":
    guard !JobKind.isReport(message) else { return false }
    return !message.text.isEmpty || !(message.attachments ?? []).isEmpty
  case "event":
    return !message.text.isEmpty && !(message.kind == CallMarker.startedKind && message.call?.callee != nil)
  case "assistant":
    return hasAssistantText(message)
  default:
    return false
  }
}

private func hasAssistantText(_ message: Message) -> Bool {
  guard case .array(let blocks)? = message.blocks else { return !contentText(message.blocks).isEmpty }
  return blocks.contains {
    $0["type"]?.stringValue == "text"
      && !($0["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

extension CallRequest {
  public static let noticeOriginKind = "call_request"

  /// The state the card shows; nil while the request waits for the owner.
  public var stateLabel: String? {
    switch status {
    case .pending: nil
    case .declined: "Declined"
    case .calling: "Calling"
    case .ended:
      switch outcome {
      case .answered: "Answered"
      case .unanswered: "Not answered"
      case .busy: "Busy"
      case .failed: "Failed"
      case nil: "Ended"
      }
    }
  }
}

private let endedCallPrefix = "voice-call:"
private let endedCallSuffix = ":ended"
private let sweptRequestPrefix = "call-request:"

/// The call request an outside call's notice stands for; nil for a call with the owner and for notices of
/// other origins.
public func callRequest(for message: Message, in requests: [CallRequest]) -> CallRequest? {
  guard message.role == "user",
    [CallMarker.originKind, CallRequest.noticeOriginKind].contains(message.origin?.kind),
    let requestID = message.requestId
  else { return nil }
  if requestID.hasPrefix(endedCallPrefix), requestID.hasSuffix(endedCallSuffix) {
    let callID = requestID.dropFirst(endedCallPrefix.count).dropLast(endedCallSuffix.count)
    guard !callID.isEmpty, !callID.contains(":") else { return nil }
    return requests.first { $0.callID == String(callID) }
  }
  if requestID.hasPrefix(sweptRequestPrefix) {
    let id = requestID.dropFirst(sweptRequestPrefix.count)
    guard !id.isEmpty, !id.contains(":") else { return nil }
    return requests.first { $0.id == String(id) }
  }
  return nil
}

/// What an outside call's notice says after the callee's name, such as "ended after 2 minutes".
public func callNoticeDetail(_ message: Message, request: CallRequest) -> String {
  let lead = "Call to \(request.callee) "
  return message.text.hasPrefix(lead) ? String(message.text.dropFirst(lead.count)) : message.text
}

/// One thing said on an outside call.
public struct CallTranscriptLine: Identifiable, Hashable, Sendable {
  public enum Speaker: Hashable, Sendable {
    /// The person the bot called.
    case callee
    case bot
  }

  public var id: String
  public var speaker: Speaker
  public var text: String
}

/// The spoken lines of a call's transcript page, in order: what the callee said and the bot's replies with text.
public func callTranscriptLines(_ messages: [Message]) -> [CallTranscriptLine] {
  messages.compactMap { message in
    switch message.role {
    case "user": CallTranscriptLine(id: message.id, speaker: .callee, text: message.text)
    case "assistant" where hasAssistantText(message):
      CallTranscriptLine(id: message.id, speaker: .bot, text: message.text)
    default: nil
    }
  }
}
