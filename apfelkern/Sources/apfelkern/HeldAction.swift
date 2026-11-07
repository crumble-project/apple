import Foundation

/// On a `held-action` event: the desktop job action an intent check held. Whether it still waits is
/// in the bot's held actions.
public struct HeldActionEvent: Codable, Hashable, Sendable {
  public static let messageKind = "held-action"

  public var id: String
  public var job: String

  public init(id: String, job: String) {
    self.id = id
    self.job = job
  }
}

/// A desktop job action an intent check held, waiting for the owner or decided.
public struct HeldAction: Identifiable, Hashable, Sendable {
  public enum Status: Hashable, Sendable {
    case pending
    case approved
    case declined
    case expired
  }

  /// A message the intent check read, written by the owner or sent by an automation of theirs.
  public struct OwnerMessage: Identifiable, Hashable, Sendable {
    public var requestID: String
    public var text: String
    public var fromAutomation: Bool

    public var id: String { requestID }

    public init(requestID: String, text: String, fromAutomation: Bool) {
      self.requestID = requestID
      self.text = text
      self.fromAutomation = fromAutomation
    }
  }

  public var id: String
  public var job: String
  public var action: String
  public var page: String?
  public var ownerMessages: [OwnerMessage]
  public var reason: String
  public var status: Status

  public init(
    id: String, job: String, action: String, page: String? = nil, ownerMessages: [OwnerMessage] = [],
    reason: String, status: Status
  ) {
    self.id = id
    self.job = job
    self.action = action
    self.page = page
    self.ownerMessages = ownerMessages
    self.reason = reason
    self.status = status
  }
}

extension HeldAction {
  init(wire: Components.Schemas.HeldAction) {
    self.init(
      id: wire.id, job: wire.job, action: wire.action, page: wire.page,
      ownerMessages: wire.ownerMessages.map {
        OwnerMessage(requestID: $0.requestId, text: $0.text, fromAutomation: $0.from == .automation)
      },
      reason: wire.reason, status: Status(wire: wire.status))
  }
}

extension HeldAction.Status {
  init(wire: Components.Schemas.HeldAction.StatusPayload) {
    self = switch wire {
    case .pending: .pending
    case .approved: .approved
    case .declined: .declined
    case .expired: .expired
    }
  }
}
