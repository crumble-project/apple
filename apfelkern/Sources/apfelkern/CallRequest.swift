import Foundation

/// A bot's proposal to phone someone other than the owner, waiting for the owner or decided.
public struct CallRequest: Identifiable, Hashable, Sendable {
  public enum Status: Hashable, Sendable {
    case pending
    case declined
    case calling
    case ended
  }

  public enum Outcome: Hashable, Sendable {
    case answered
    case unanswered
    case busy
    case failed
  }

  public static let toolName = "request_call"

  public var id: String
  /// The bot that asked.
  public var agentID: String
  public var number: String
  /// Who the bot calls.
  public var callee: String
  public var goal: String
  /// What the bot says first when the callee answers.
  public var opening: String
  public var status: Status
  public var callID: String?
  /// The conversation holding the call's transcript.
  public var conversationID: String?
  public var outcome: Outcome?
  public var error: String?
  public var requestedAt: String
  public var decidedAt: String?
  public var endedAt: String?

  /// A `request_call` result carries the request as it was saved. Whether it still waits is in the
  /// bot's requests.
  public init?(message: Message) {
    guard message.role == "toolResult", message.toolName == Self.toolName, message.isError != true,
      let details = message.toolDetails,
      let wire: Components.Schemas.CallRequest = try? details.decoded()
    else { return nil }
    self.init(wire: wire)
  }
}

extension CallRequest {
  init(wire: Components.Schemas.CallRequest) {
    id = wire.id
    agentID = wire.agentId
    number = wire.number
    callee = wire.callee
    goal = wire.goal
    opening = wire.opening
    status = switch wire.status {
    case .pending: .pending
    case .declined: .declined
    case .calling: .calling
    case .ended: .ended
    }
    callID = wire.callId
    conversationID = wire.conversationId
    outcome = switch wire.outcome {
    case .answered: .answered
    case .unanswered: .unanswered
    case .busy: .busy
    case .failed: .failed
    case ._empty_, nil: nil
    }
    error = wire.error?.nilIfEmpty
    requestedAt = wire.requestedAt
    decidedAt = wire.decidedAt
    endedAt = wire.endedAt
  }
}
