import Foundation

/// How long a request that reads a GitHub repository through the server may take.
private let gitHubTimeout: TimeInterval = 120

extension APIClient {
  public func sharedSkills() async throws -> [SharedSkill] {
    try await invoke { try await $0.listSkills(.init()).ok.body.json.map(SharedSkill.init(wire:)) }
  }

  public func sharedSkill(_ id: String) async throws -> SkillPackage {
    try await invoke { SkillPackage(wire: try await $0.getSkill(.init(path: .init(id: id))).ok.body.json) }
  }

  public func createSharedSkill(
    name: String, description: String = "", instructions: String, documents: [SkillDocument] = []
  ) async throws -> SharedSkill {
    let documents = documents.map {
      Operations.CreateSkill.Input.Body.JsonPayload.DocumentsPayloadPayload(content: $0.content, path: $0.path)
    }
    return try await invoke {
      var created = try SharedSkill(wire: await $0.createSkill(.init(body: .json(.init(
        description: description.isEmpty ? nil : description, documents: documents.isEmpty ? nil : documents,
        instructions: instructions, name: name)))).created.body.json)
      created.description = description
      return created
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

  /// Changes one bot's use of one shared skill, so it can't undo another client's assignment.
  /// Returns true when the bot was already in the requested state.
  @discardableResult
  public func assignSharedSkill(_ skillID: String, agentID: String, assigned: Bool) async throws -> Bool {
    try await invoke {
      try await $0.assignSkillBot(.init(
        path: .init(id: skillID), body: .json(.init(assigned: assigned, botId: agentID)))).ok.body.json.skipped
    }
  }

  /// Lists the skills at `location`: `owner/repo` or a github.com URL.
  public func browseSkillRepository(location: String) async throws -> SkillListing {
    try await invoke(timeout: gitHubTimeout) {
      SkillListing(wire: try await $0.browseSkillRepository(.init(body: .json(.init(location: location))))
        .ok.body.json)
    }
  }

  /// Installs skills from the listing's commit, all or none, and turns them on for `botIDs`.
  public func installSkills(from listing: SkillListing, paths: [String], botIDs: [String]) async throws {
    try await invoke(timeout: gitHubTimeout) {
      _ = try await $0.installSkills(.init(body: .json(.init(
        botIds: botIDs, branch: listing.branch, commit: listing.commit, paths: paths,
        repository: listing.repository)))).created
    }
  }

  /// Checks every installed skill's branch now and returns the ones that couldn't be read.
  public func checkSkillUpdates() async throws -> [SkillCheckFailure] {
    try await invoke(timeout: gitHubTimeout) {
      try await $0.checkSkillUpdates(.init()).ok.body.json.failed.map {
        SkillCheckFailure(repository: $0.repository, branch: $0.branch, message: $0.message)
      }
    }
  }

  public func pendingSkillUpdate(_ id: String) async throws -> PendingSkillUpdate {
    try await invoke(timeout: gitHubTimeout) {
      PendingSkillUpdate(wire: try await $0.getPendingSkillUpdate(.init(path: .init(id: id))).ok.body.json)
    }
  }

  public func applySkillUpdate(_ id: String) async throws -> SkillPackage {
    try await invoke(timeout: gitHubTimeout) {
      SkillPackage(wire: try await $0.applySkillUpdate(.init(path: .init(id: id))).ok.body.json)
    }
  }
}
