import Foundation

extension AppModel {
  func openSkillForm(_ id: String) {
    var form = SkillDraft(skillID: id, agentID: nil)
    if let skill = sharedSkills.first(where: { $0.id == id }) {
      form.name = skill.name
      form.instructions = skill.instructions
    }
    skillDraft = form
  }

  func openPersonalSkillForm(agentID: String, skillID: String = "") {
    guard let agent = agents.first(where: { $0.id == agentID }) else { return }
    var form = SkillDraft(skillID: skillID, agentID: agentID)
    if let skill = agent.skills?.first(where: { $0.id.uuidString == skillID }) {
      form.name = skill.name
      form.instructions = skill.instructions
    }
    skillDraft = form
  }

  private func savePersonalSkill(
    _ form: SkillDraft, agentID: String, name: String, instructions: String
  ) {
    guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
    let previous = agents[index].skills ?? []
    var updated = previous
    let skill = Skill(name: name, instructions: instructions)
    if let existing = previous.firstIndex(where: { $0.id.uuidString == form.skillID }) {
      var replacement = previous[existing]
      replacement.name = name
      replacement.instructions = instructions
      updated[existing] = replacement
    } else {
      updated.append(skill)
    }
    skillDraft = nil
    optimisticMutation(
      key: "agent-skill:\(agentID):skills",
      update: { [self] in
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].skills = updated
      },
      rollback: { [self] in
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].skills = previous
        if route == .skills, skillDraft == nil { skillDraft = form }
      },
      work: { client in
        _ = try await client.updateAgent(
          agentID, patch: ["skills": try JSONValue(encoding: updated)])
        return { [self] in
          // Keep fields changed by another editor or a newer optimistic mutation intact.
          if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].skills = updated
          }
        }
      })
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
    let isNew = form.skillID.isEmpty
    let provisionalID = isNew ? "pending-skill-" + newRequestID() : form.skillID
    let provisional = SharedSkill(
      id: provisionalID, name: name, instructions: instructions, source: nil, path: nil)
    let old = sharedSkills.first { $0.id == form.skillID }
    skillDraft = nil
    optimisticMutation(
      key: "skill:\(provisionalID)",
      update: { [self] in
        if let index = sharedSkills.firstIndex(where: {
          $0.id == provisionalID || $0.id == form.skillID
        }) {
          sharedSkills[index] = provisional
        } else {
          sharedSkills.append(provisional)
        }
      },
      rollback: { [self] in
        sharedSkills.removeAll { $0.id == provisionalID }
        if let old { sharedSkills.append(old) }
        if route == .skills, skillDraft == nil { skillDraft = form }
      },
      work: { client in
        if isNew {
          let saved = try await client.createSharedSkill(name: name, instructions: instructions)
          return { [self] in
            if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID }) {
              sharedSkills[index] = saved
            }
          }
        }
        let saved = try await client.updateSharedSkill(
          form.skillID, name: name, instructions: instructions)
        return { [self] in
          if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID }) {
            sharedSkills[index] = saved
          }
        }
      })
  }

  func deleteSharedSkill(_ id: String) {
    guard let old = sharedSkills.first(where: { $0.id == id }),
      let index = sharedSkills.firstIndex(where: { $0.id == id })
    else { return }
    let affectedAgents = agents.compactMap { agent -> (String, [String])? in
      guard agent.sharedSkills?.contains(id) == true else { return nil }
      return (agent.id, agent.sharedSkills ?? [])
    }
    optimisticMutation(
      key: "skill:\(id)",
      update: { [self] in
        sharedSkills.removeAll { $0.id == id }
        for index in agents.indices { agents[index].sharedSkills?.removeAll { $0 == id } }
      },
      rollback: { [self] in
        sharedSkills.insert(old, at: min(index, sharedSkills.count))
        for (agentID, memberships) in affectedAgents {
          if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].sharedSkills = memberships
          }
        }
      },
      work: { client in
        try await client.deleteSharedSkill(id)
        return nil
      })
  }

  func setSharedSkill(_ skillID: String, for agentID: String, enabled: Bool) {
    guard !skillID.isEmpty, !agentID.isEmpty,
      let index = agents.firstIndex(where: { $0.id == agentID }),
      sharedSkills.contains(where: { $0.id == skillID && !$0.isDefault })
    else { return }
    let previous = agents[index].sharedSkills ?? []
    var memberships = Set(previous)
    if enabled { memberships.insert(skillID) } else { memberships.remove(skillID) }
    let updated = memberships.sorted()
    guard updated != previous.sorted() else { return }
    optimisticMutation(
      key: "agent-skill:\(agentID):sharedSkills",
      update: { [self] in
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].sharedSkills = updated
      },
      rollback: { [self] in
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].sharedSkills = previous
      },
      work: { client in
        _ = try await client.updateAgent(
          agentID, patch: ["sharedSkills": .array(updated.map(JSONValue.string))])
        return { [self] in
          guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
          agents[index].sharedSkills = updated
        }
      })
  }

  func deletePersonalSkill(_ skillID: String, from agentID: String) {
    guard let index = agents.firstIndex(where: { $0.id == agentID }),
      let skillIndex = agents[index].skills?.firstIndex(where: { $0.id.uuidString == skillID })
    else { return }
    let previous = agents[index].skills ?? []
    var updated = previous
    updated.remove(at: skillIndex)
    optimisticMutation(
      key: "agent-skill-personal:\(agentID):\(skillID)",
      update: { [self] in
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].skills = updated
      },
      rollback: { [self] in
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].skills = previous
      },
      work: { client in
        _ = try await client.updateAgent(
          agentID, patch: ["skills": try JSONValue(encoding: updated)])
        return { [self] in
          if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].skills = updated
          }
        }
      })
  }
}
