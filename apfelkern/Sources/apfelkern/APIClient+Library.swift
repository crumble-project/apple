import Foundation

extension APIClient {
  public func memories(_ agentID: String?) async throws -> [Memory] {
    try await invoke { client in
      if let agentID {
        return try await client.listAgentMemories(.init(path: .init(id: agentID))).ok.body.json.map(Memory.init(wire:))
      }
      return try await client.listSharedMemories(.init()).ok.body.json.map(Memory.init(wire:))
    }
  }

  public func addMemory(_ agentID: String?, content: String) async throws -> Memory {
    try await invoke { client in
      if let agentID {
        return try Memory(wire: await client.createAgentMemory(.init(
          path: .init(id: agentID), body: .json(.init(content: content)))).created.body.json)
      }
      return try Memory(wire: await client.createSharedMemory(
        .init(body: .json(.init(content: content)))).created.body.json)
    }
  }

  public func updateMemory(_ agentID: String?, memoryID: String, content: String) async throws -> Memory {
    try await invoke { client in
      if let agentID {
        return Memory(wire: try requestModel(required(try await client.updateAgentMemory(.init(
          path: .init(id: agentID, memoryId: memoryID), body: .json(.init(content: content)))).ok.body.json)))
      }
      return Memory(wire: try requestModel(required(try await client.updateSharedMemory(.init(
        path: .init(id: memoryID), body: .json(.init(content: content)))).ok.body.json)))
    }
  }

  public func deleteMemory(_ agentID: String?, memoryID: String) async throws {
    try await invoke { client in
      if let agentID {
        _ = try await client.deleteAgentMemory(.init(path: .init(id: agentID, memoryId: memoryID))).noContent
      } else {
        _ = try await client.deleteSharedMemory(.init(path: .init(id: memoryID))).noContent
      }
    }
  }

  public func sharedSkills() async throws -> [SharedSkill] {
    try await invoke { try await $0.listSkills(.init()).ok.body.json.map(SharedSkill.init(wire:)) }
  }

  public func createSharedSkill(name: String, instructions: String) async throws -> SharedSkill {
    try await invoke {
      try SharedSkill(wire: await $0.createSkill(.init(
        body: .json(.init(instructions: instructions, name: name)))).created.body.json)
    }
  }

  public func updateSharedSkill(_ id: String, name: String, instructions: String) async throws -> SharedSkill {
    try await invoke {
      SharedSkill(wire: try requestModel(required(try await $0.updateSkill(.init(
        path: .init(id: id), body: .json(.init(instructions: instructions, name: name)))).ok.body.json))
        as Components.Schemas.Skill)
    }
  }

  public func deleteSharedSkill(_ id: String) async throws {
    try await invoke { _ = try await $0.deleteSkill(.init(path: .init(id: id))).noContent }
  }

  public func schedules() async throws -> [Schedule] {
    try await invoke { try await $0.listSchedules(.init()).ok.body.json.map(Schedule.init(wire:)) }
  }

  public func createSchedule(_ payload: [String: JSONValue]) async throws -> Schedule {
    let body: Operations.CreateSchedule.Input.Body.JsonPayload = try requestModel(payload)
    return try await invoke(nullFields: Set(payload.filter { $0.value == .null }.keys)) {
      try Schedule(wire: await $0.createSchedule(.init(body: .json(body))).created.body.json)
    }
  }

  public func updateSchedule(_ id: String, patch: [String: JSONValue]) async throws -> Schedule {
    let body: Operations.UpdateSchedule.Input.Body.JsonPayload = try requestModel(patch)
    return try await invoke(nullFields: Set(patch.filter { $0.value == .null }.keys)) {
      Schedule(wire: try requestModel(required(try await $0.updateSchedule(
        .init(path: .init(id: id), body: .json(body))).ok.body.json)))
    }
  }

  public func deleteSchedule(_ id: String) async throws {
    try await invoke { _ = try await $0.deleteSchedule(.init(path: .init(id: id))).noContent }
  }

  public func runSchedule(_ id: String) async throws -> Execution {
    try await invoke {
      let response = try await $0.runSchedule(.init(path: .init(id: id))).accepted.body.json
      guard response.admitted else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Schedule run was not admitted"))
      }
      let result = try required(response.result)
      return Execution(
        id: try required(result.id), agentId: result.agentId, conversationId: result.conversationId,
        status: result.status, prompt: result.prompt, error: result.error,
        createdAt: result.createdAt, updatedAt: result.updatedAt)
    }
  }

  public func executions() async throws -> [Execution] {
    try await invoke { try await $0.listExecutions(.init()).ok.body.json.map(Execution.init(wire:)) }
  }
}
