extension APIClient {
  public func botSkills(agentID: String) async throws -> [BotSkill] {
    try await invoke {
      try await $0.listAgentSkills(.init(path: .init(id: agentID))).ok.body.json
        .map { BotSkill(wire: $0, agentID: agentID) }
    }
  }

  public func createBotSkill(agentID: String, name: String, instructions: String) async throws -> BotSkill {
    try await invoke {
      BotSkill(wire: try await $0.createAgentSkill(.init(
        path: .init(id: agentID), body: .json(.init(instructions: instructions, name: name))
      )).created.body.json, agentID: agentID)
    }
  }

  public func updateBotSkill(agentID: String, skillID: String, name: String, instructions: String)
    async throws -> BotSkill {
    try await updateBotSkill(agentID: agentID, skillID: skillID, body: .init(instructions: instructions, name: name))
  }

  public func setBotSkillPinned(agentID: String, skillID: String, pinned: Bool) async throws -> BotSkill {
    try await updateBotSkill(agentID: agentID, skillID: skillID, body: .init(pinned: pinned))
  }

  private func updateBotSkill(
    agentID: String, skillID: String, body: Operations.UpdateAgentSkill.Input.Body.JsonPayload
  ) async throws -> BotSkill {
    try await invoke {
      BotSkill(wire: try requestModel(required(try await $0.updateAgentSkill(.init(
        path: .init(id: agentID, skillId: skillID), body: .json(body))).ok.body.json))
        as Components.Schemas.SkillPackage, agentID: agentID)
    }
  }

  public func deleteBotSkill(agentID: String, skillID: String) async throws {
    try await invoke {
      _ = try await $0.deleteAgentSkill(.init(path: .init(id: agentID, skillId: skillID))).noContent
    }
  }

  /// Changes one bot's use of one shared skill, so it can't undo another client's assignment.
  public func assignSharedSkill(_ skillID: String, agentID: String, assigned: Bool) async throws {
    try await invoke {
      _ = try await $0.assignSkillBot(.init(
        path: .init(id: skillID), body: .json(.init(assigned: assigned, botId: agentID)))).ok
    }
  }
}
