import Foundation

/// The group a form creates or edits: its name and two to six member bots.
public struct GroupDraft: Identifiable, Sendable {
  public static let memberRange = 2...6
  public static let nameLimit = 80

  public let id = UUID()
  /// Nil for a new group.
  public var groupID: String?
  public var name: String
  public var memberIDs: [String]

  public init(groupID: String? = nil, name: String = "", memberIDs: [String] = []) {
    self.groupID = groupID
    self.name = name
    self.memberIDs = memberIDs
  }

  public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  public var isFull: Bool { memberIDs.count >= Self.memberRange.upperBound }

  public var isValid: Bool {
    !trimmedName.isEmpty && trimmedName.count <= Self.nameLimit && Self.memberRange.contains(memberIDs.count)
  }

  public func includes(_ agentID: String) -> Bool { memberIDs.contains(agentID) }

  public mutating func setMember(_ agentID: String, included: Bool) {
    memberIDs.removeAll { $0 == agentID }
    if included { memberIDs.append(agentID) }
  }
}

/// One row of a group transcript.
public enum GroupChatRow: Identifiable {
  case older
  case time(String, String)
  case message(Message, reactions: [Reaction.Mark])
  case working([Agent])
  case failure(agentID: String, name: String, error: String)
  case paused

  public var id: String {
    switch self {
    case .older: "older"
    case .time(let id, _): "time:" + id
    case .message(let message, _): message.id
    case .working: "working"
    case .failure(let agentID, _, _): "failure:" + agentID
    case .paused: "paused"
    }
  }

  /// Owner and bot messages with reactions beside the message they answer, then who is answering,
  /// failed turns, and the paused state.
  public static func rows(messages: [Message], snapshot: GroupChatSnapshot?, agents: [Agent], hasMore: Bool)
    -> [GroupChatRow] {
    var rows: [GroupChatRow] = hasMore ? [.older] : []
    var last: Int64 = 0
    let reactions = Reaction.byReplyTarget(messages)
    for message in messages where shown(message) {
      if let timestamp = message.timestamp, timestamp > 0 {
        if timestamp - last > 30 * 60 * 1000 {
          rows.append(.time(message.id, timeLabel(Date(timeIntervalSince1970: Double(timestamp) / 1000))))
        }
        last = timestamp
      }
      rows.append(.message(message, reactions: reactions[message.id] ?? []))
    }
    guard let snapshot else { return rows }
    let agent = { (id: String) in agents.first { $0.id == id } }
    let working = snapshot.activity.members.filter { $0.status == .running }.compactMap { agent($0.agentId) }
    if !working.isEmpty { rows.append(.working(working)) }
    for member in snapshot.activity.members {
      if let error = member.error?.nilIfEmpty {
        rows.append(.failure(agentID: member.agentId, name: agent(member.agentId)?.name ?? "A bot", error: error))
      }
    }
    if snapshot.activity.paused { rows.append(.paused) }
    return rows
  }

  /// A bot's turn that only called tools or reacted leaves an assistant entry with no text to show.
  static func shown(_ message: Message) -> Bool {
    guard message.role == "user" || message.role == "assistant" else { return false }
    return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !(message.attachments ?? []).isEmpty
  }
}

extension GroupMemberActivity.Status {
  /// What a member is doing, in a sentence that names it.
  public func label(for name: String) -> String {
    switch self {
    case .running: "\(name) is answering"
    case .queued: "\(name) answers next"
    case .disabled: "\(name) is disabled and skipped"
    case .idle: name
    }
  }
}

extension GroupChat {
  /// Optimistic group messages share bot chat delivery under a key no bot ID can take.
  public static func deliveryKey(_ id: String) -> String { "group:" + id }
}

extension ActivityEvent {
  /// Who answered in which group, for a notification title.
  public var groupTitle: String { "\(agentName) in \(groupName ?? "a group chat")" }
}
