import Foundation

/// A conversation between the owner and two to six bots, with one shared transcript.
public struct GroupChat: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  /// Member bots in the order they joined.
  public var memberIds: [String]
  public var createdAt: String
  public var updatedAt: String

  public init(id: String, name: String, memberIds: [String], createdAt: String, updatedAt: String) {
    self.id = id
    self.name = name
    self.memberIds = memberIds
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// What one member is doing in a group: answering, waiting for its turn, or nothing.
public struct GroupMemberActivity: Codable, Hashable, Sendable {
  public enum Status: String, Codable, Hashable, Sendable {
    case idle, queued, running, disabled
  }

  public var agentId: String
  public var status: Status
  /// Why the member's latest turn failed.
  public var error: String?

  public init(agentId: String, status: Status, error: String? = nil) {
    self.agentId = agentId
    self.status = status
    self.error = error
  }
}

public struct GroupActivity: Codable, Hashable, Sendable {
  /// Bots used up their turns since the owner's last message; the owner's next message resumes them.
  public var paused: Bool
  public var botTurns: Int
  public var members: [GroupMemberActivity]

  public var isRunning: Bool { members.contains { $0.status == .running || $0.status == .queued } }

  public init(paused: Bool = false, botTurns: Int = 0, members: [GroupMemberActivity] = []) {
    self.paused = paused
    self.botTurns = botTurns
    self.members = members
  }

  public func member(_ agentID: String) -> GroupMemberActivity? {
    members.first { $0.agentId == agentID }
  }
}

/// A group chat with its newest messages and what its members are doing, as the snapshot endpoint and stream send it.
public struct GroupChatSnapshot: Codable, Sendable {
  public var groupChat: GroupChat
  public var activity: GroupActivity
  public var messages: [Message]
  public var hasMore: Bool
  public var oldestEntryId: String?

  public init(
    groupChat: GroupChat, activity: GroupActivity = GroupActivity(), messages: [Message] = [],
    hasMore: Bool = false, oldestEntryId: String? = nil
  ) {
    self.groupChat = groupChat
    self.activity = activity
    self.messages = messages
    self.hasMore = hasMore
    self.oldestEntryId = oldestEntryId
  }

  public init(from decoder: Decoder) throws {
    let event = try Components.Schemas.EventGroupChatSnapshot(from: decoder)
    let wire = try JSONDecoder().decode(
      Components.Schemas.GroupChatSnapshot.self, from: JSONEncoder().encode(event))
    try self.init(wire: wire)
  }
}

/// A file on its way into a group chat, in the shape the group messages endpoint takes.
public typealias OutgoingGroupAttachment =
  Operations.SendGroupMessage.Input.Body.JsonPayload.AttachmentsPayloadPayload

extension OutgoingGroupAttachment {
  public init(_ attachment: OutgoingAttachment) {
    self.init(data: attachment.data, mimeType: attachment.mimeType, name: attachment.name)
  }
}

extension GroupChat {
  init(wire: Components.Schemas.GroupChat) {
    self.init(id: wire.id, name: wire.name, memberIds: wire.memberIds, createdAt: wire.createdAt,
              updatedAt: wire.updatedAt)
  }
}

extension GroupActivity {
  init(wire: Components.Schemas.GroupActivity) {
    self.init(
      paused: wire.paused, botTurns: Int(exactly: wire.botTurns) ?? 0,
      members: wire.members.map {
        GroupMemberActivity(
          agentId: $0.agentId, status: GroupMemberActivity.Status(rawValue: $0.status.rawValue) ?? .idle,
          error: $0.error)
      })
  }
}

extension GroupChatSnapshot {
  init(wire: Components.Schemas.GroupChatSnapshot) throws {
    self.init(
      groupChat: GroupChat(wire: wire.value2.groupChat), activity: GroupActivity(wire: wire.value2.activity),
      messages: try wire.value1.messages.map(Message.init(wire:)), hasMore: wire.value1.hasMore,
      oldestEntryId: wire.value1.oldestEntryId)
  }
}

extension APIClient {
  public func groupChats() async throws -> [GroupChat] {
    try await invoke { try await $0.listGroupChats(.init()).ok.body.json.map(GroupChat.init(wire:)) }
  }

  public func createGroupChat(name: String, memberIDs: [String]) async throws -> GroupChat {
    try await invoke {
      GroupChat(wire: try await $0.createGroupChat(.init(
        body: .json(.init(memberIds: memberIDs, name: name)))).created.body.json)
    }
  }

  /// Renames a group or replaces its members; a nil field stays as it is.
  public func updateGroupChat(_ id: String, name: String? = nil, memberIDs: [String]? = nil)
    async throws -> GroupChat {
    try await invoke {
      GroupChat(wire: try await $0.updateGroupChat(.init(
        path: .init(id: id), body: .json(.init(memberIds: memberIDs, name: name)))).ok.body.json)
    }
  }

  public func deleteGroupChat(_ id: String) async throws {
    try await invoke { _ = try await $0.deleteGroupChat(.init(path: .init(id: id))).noContent }
  }

  public func groupChat(_ id: String, limit: Int = 0) async throws -> GroupChatSnapshot {
    try await invoke {
      try GroupChatSnapshot(wire: await $0.getGroupChatSnapshot(.init(
        path: .init(id: id), query: .init(limit: limit > 0 ? limit : nil))).ok.body.json)
    }
  }

  public func groupChatHistory(_ id: String, before: String, limit: Int) async throws -> ChatHistoryResponse {
    try await invoke {
      try ChatHistoryResponse(wire: await $0.getGroupChatHistory(.init(
        path: .init(id: id), query: .init(limit: limit > 0 ? limit : nil, before: before.nilIfEmpty)
      )).ok.body.json)
    }
  }

  public func sendGroupMessage(
    _ id: String, content: String, requestID: String, replyTo: String = "",
    attachments: [OutgoingAttachment] = []
  ) async throws {
    let body = Operations.SendGroupMessage.Input.Body.JsonPayload(
      attachments: attachments.isEmpty ? nil : attachments.map(OutgoingGroupAttachment.init),
      content: content, replyTo: replyTo.nilIfEmpty, requestId: requestID)
    try await invoke(timeout: attachments.isEmpty ? 20 : 120) {
      _ = try await $0.sendGroupMessage(.init(path: .init(id: id), body: .json(body))).created
    }
  }

  /// Ends every running bot turn in the group and drops the queued ones.
  public func stopGroupChat(_ id: String) async throws {
    try await invoke { _ = try await $0.stopGroupChat(.init(path: .init(id: id))).noContent }
  }

  public func groupAttachment(_ id: String, entryID: String, index: Int) async throws -> Data {
    try await invoke {
      let body = try await $0.getGroupAttachment(.init(
        path: .init(id: id, entryId: entryID, index: index))).ok.body.any
      return try await Data(collecting: body, upTo: .max)
    }
  }

  /// Streams the group's snapshot on connect and after every change, as JSON for `GroupChatSnapshot`.
  public func groupChatEvents(_ id: String, onEvent: @Sendable (String) async -> Void) async throws -> Never {
    let body = try await invoke(timeout: serverSentEventsIdleTimeout) {
      try await $0.streamGroupChatEvents(.init(path: .init(id: id))).ok.body.textEventStream
    }
    try await events(body, parser: SSEParser(snapshots: .group), onEvent: onEvent)
  }
}
