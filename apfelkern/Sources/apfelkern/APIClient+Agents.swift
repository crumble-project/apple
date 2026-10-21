import Foundation

extension APIClient {
  public func agents() async throws -> [Agent] {
    try await invoke { try await $0.listAgents(.init()).ok.body.json.map(Agent.init(wire:)) }
  }

  public func createAgent(_ agent: Agent) async throws -> Agent {
    let body: Operations.CreateAgent.Input.Body.JsonPayload = try requestModel(agent)
    return try await invoke {
      Agent(wire: try await $0.createAgent(.init(body: .json(body))).created.body.json)
    }
  }

  /// A `null` value clears a nullable field, such as `desktopModel`.
  public func updateAgent(_ id: String, patch: [String: JSONValue]) async throws -> Agent {
    let body: Operations.UpdateAgent.Input.Body.JsonPayload = try requestModel(patch)
    return try await invoke(nullFields: Set(patch.filter { $0.value == .null }.keys)) {
      Agent(wire: try requestModel(required(try await $0.updateAgent(
        .init(path: .init(id: id), body: .json(body))).ok.body.json)) as Components.Schemas.Agent)
    }
  }

  public func deleteAgent(_ id: String) async throws {
    try await invoke { _ = try await $0.deleteAgent(.init(path: .init(id: id))).noContent }
  }

  public func duplicateAgent(_ id: String) async throws -> Agent {
    try await invoke {
      Agent(wire: try requestModel(required(try await $0.duplicateAgent(
        .init(path: .init(id: id))).created.body.json)) as Components.Schemas.Agent)
    }
  }

  public func chat(_ agentID: String) async throws -> ChatSnapshot {
    try await invoke { try ChatSnapshot(wire: await $0.getChat(.init(path: .init(id: agentID))).ok.body.json) }
  }

  public func chatHistory(_ agentID: String, before: String, limit: Int) async throws -> ChatHistoryResponse {
    try await invoke {
      try ChatHistoryResponse(wire: await $0.getChatHistory(.init(
        path: .init(id: agentID), query: .init(limit: limit > 0 ? limit : nil, before: before.nilIfEmpty)
      )).ok.body.json)
    }
  }

  public func capabilities() async throws -> ServerCapabilities {
    try await invoke {
      let capabilities = try await $0.getCapabilities(.init()).ok.body.json
      return ServerCapabilities(coding: capabilities.coding, desktop: capabilities.desktop)
    }
  }

  public func codingJobs(_ agentID: String) async throws -> [CodingJob] {
    try await invoke {
      try await $0.listCodingJobs(.init(path: .init(id: agentID))).ok.body.json.jobs.map {
        CodingJob(
          name: $0.name, conversationId: $0.conversationId, status: $0.status.rawValue,
          usage: JobUsage(document: $0.usage))
      }
    }
  }

  public func codingJobHistory(_ agentID: String, name: String, before: String, limit: Int)
    async throws -> ChatHistoryResponse {
    try await invoke {
      try ChatHistoryResponse(wire: await $0.getCodingJobHistory(.init(
        path: .init(id: agentID, name: name),
        query: .init(limit: limit > 0 ? limit : nil, before: before.nilIfEmpty)
      )).ok.body.json)
    }
  }

  public func sendChatMessage(
    _ agentID: String, content: String, requestID: String, replyTo: String,
    attachments: [OutgoingAttachment] = [], timezone: String = TimeZone.current.identifier
  ) async throws {
    let body = Operations.SendMessage.Input.Body.JsonPayload(
      attachments: attachments.isEmpty ? nil : attachments,
      content: content, replyTo: replyTo.nilIfEmpty, requestId: requestID, timezone: timezone)
    try await invoke(timeout: attachments.isEmpty ? 20 : 120) {
      _ = try await $0.sendMessage(.init(path: .init(id: agentID), body: .json(body))).accepted
    }
  }

  public func attachment(_ agentID: String, entryID: String, index: Int) async throws -> Data {
    try await invoke {
      let body = try await $0.getAttachment(.init(
        path: .init(id: agentID, entryId: entryID, index: index))).ok.body.image_Ast_
      return try await Data(collecting: body, upTo: .max)
    }
  }

  public func abortChat(_ agentID: String) async throws {
    try await invoke { _ = try await $0.abortChat(.init(path: .init(id: agentID))).noContent }
  }

  public func compactChat(_ agentID: String) async throws {
    try await invoke { _ = try await $0.compactChat(.init(path: .init(id: agentID))).accepted }
  }
}
