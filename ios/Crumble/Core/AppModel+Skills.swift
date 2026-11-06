import apfelkern
import Foundation

extension AppModel: SkillHost {
  func reloadSkills() {
    if let client { sharedSkillBoard.refresh(client: client) }
    let mutationVersion = mutationRevision
    request { client in
      let loadedBots = try await client.agents()
      return { [self] in
        for agent in loadedBots { botSkillBoard.refresh(agentID: agent.id, client: client) }
        guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
        agents = loadedBots
      }
    }
  }

  func openSkillForm(_ id: String) {
    var form = SkillDraft(skillID: id, agentID: nil)
    if let skill = sharedSkills.first(where: { $0.id == id }) {
      form.name = skill.name
      form.instructions = skill.instructions
      form.usedBy = agents.using(skill: id)
    }
    skillDraft = form
  }

  func openPersonalSkillForm(agentID: String, skillID: String = "") {
    var form = SkillDraft(skillID: skillID, agentID: agentID)
    if let skill = botSkillBoard.skill(skillID, agentID: agentID) {
      form.name = skill.name
      form.instructions = skill.instructions
    }
    skillDraft = form
  }

  private func savePersonalSkill(
    _ form: SkillDraft, agentID: String, name: String, instructions: String
  ) {
    guard let client else {
      errorText = "Connect to your server in Settings."
      return
    }
    errorText = ""
    let saving = botSkillBoard.save(
      agentID: agentID, skillID: form.skillID.nilIfEmpty, name: name, instructions: instructions,
      client: client
    ) { [self] message in
      if route == .skills || agentDraft?.agentID == agentID, skillDraft == nil { skillDraft = form }
      errorText = message
    }
    if saving { skillDraft = nil }
  }

  func saveSkill() {
    guard let form = skillDraft else { return }
    let name = form.name.trimmingCharacters(in: .whitespaces)
    let instructions = form.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !instructions.isEmpty else {
      errorText = "Each skill needs a name and instructions."
      return
    }
    if let agentID = form.agentID {
      savePersonalSkill(form, agentID: agentID, name: name, instructions: instructions)
      return
    }
    saveSharedSkill(form, name: name, instructions: instructions)
  }

  private func saveSharedSkill(_ form: SkillDraft, name: String, instructions: String) {
    let saving = saveSharedSkill(
      skillID: form.skillID.nilIfEmpty, name: name, instructions: instructions, usedBy: form.usedBy
    ) { [self] message in
      if route == .skills, skillDraft == nil { skillDraft = form }
      errorText = message
    }
    if saving { skillDraft = nil }
  }

  func loadBotSkills(agentID: String) {
    guard let client else { return }
    botSkillBoard.refresh(agentID: agentID, client: client)
  }

  func deleteBotSkill(_ skill: BotSkill) {
    guard let client else { return }
    botSkillBoard.delete(skill, client: client)
  }

  func setBotSkillPinned(_ skill: BotSkill, pinned: Bool) {
    guard let client else { return }
    botSkillBoard.setPinned(skill, pinned: pinned, client: client)
  }
}
