import apfelkern
import Foundation

extension AppModel {
    func openSkillForm(_ id: String) {
        var form = SkillDraft(skillID: id, agentID: nil, personal: false)
        if let skill = sharedSkills.first(where: { $0.id == id }) {
            form.name = skill.name
            form.instructions = skill.instructions
        }
        skillDraft = form
    }

    func openPersonalSkillForm(agentID: String, skillID: String = "") {
        var form = SkillDraft(skillID: skillID, agentID: agentID, personal: true)
        if let skill = agents.first(where: { $0.id == agentID })?.skills?.first(where: {
            $0.id.uuidString == skillID
        }) {
            form.name = skill.name
            form.instructions = skill.instructions
        }
        skillDraft = form
    }

    func saveSkill() {
        guard let form = skillDraft else { return }
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let instructions = form.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !instructions.isEmpty else {
            errorText = "Each skill needs a name and instructions."
            return
        }
        if form.personal {
            savePersonalSkill(form, name: name, instructions: instructions)
        } else {
            saveSharedSkill(form, name: name, instructions: instructions)
        }
    }

    private func savePersonalSkill(_ form: SkillDraft, name: String, instructions: String) {
        guard let agentID = form.agentID, let index = agents.firstIndex(where: { $0.id == agentID }) else {
            errorText = "Choose which bot owns this skill."
            return
        }
        var skills = agents[index].skills ?? []
        if let skillIndex = skills.firstIndex(where: { $0.id.uuidString == form.skillID }) {
            skills[skillIndex].name = name
            skills[skillIndex].instructions = instructions
        } else {
            skills.append(Skill(name: name, instructions: instructions))
        }
        if saveAgentSkills(agentID: agentID, skills: skills, draftToRestore: form) {
            skillDraft = nil
        }
    }

    private func saveSharedSkill(_ form: SkillDraft, name: String, instructions: String) {
        let isNew = form.skillID.isEmpty
        let provisionalID = isNew ? "pending-skill-" + newRequestID() : form.skillID
        let provisional = SharedSkill(id: provisionalID, name: name, instructions: instructions, source: nil, path: nil)
        let old = sharedSkills.first { $0.id == form.skillID }
        let mutationKey = "skill:\(provisionalID)"
        guard client != nil, !pendingMutations.contains(mutationKey) else { return }
        skillDraft = nil
        optimisticMutation(
            key: mutationKey,
            update: { [self] in
                if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID || $0.id == form.skillID }) {
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
                let saved = try await client.updateSharedSkill(form.skillID, name: name, instructions: instructions)
                return { [self] in
                    if let index = sharedSkills.firstIndex(where: { $0.id == provisionalID }) {
                        sharedSkills[index] = saved
                    }
                }
            })
    }

    func deletePersonalSkill(agentID: String, skillID: String) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        saveAgentSkills(agentID: agentID, skills: (agent.skills ?? []).filter { $0.id.uuidString != skillID })
    }

    @discardableResult
    func saveAgentSkills(agentID: String, skills: [Skill], draftToRestore: SkillDraft? = nil) -> Bool {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return false }
        let key = "agent-skills:\(agentID)"
        guard client != nil, !pendingMutations.contains(key) else { return false }
        let old = agents[agentIndex].skills ?? []
        optimisticMutation(
            key: key,
            update: { [self] in
                guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
                agents[index].skills = skills
            },
            rollback: { [self] in
                if let index = agents.firstIndex(where: { $0.id == agentID }) { agents[index].skills = old }
                if let draftToRestore, route == .skills, skillDraft == nil { skillDraft = draftToRestore }
            },
            work: { client in
                let saved = try await client.updateAgent(agentID, patch: ["skills": try JSONValue(encoding: skills)])
                return { [self] in
                    if let index = agents.firstIndex(where: { $0.id == agentID }) {
                        agents[index].skills = saved.skills
                    }
                }
            })
        return true
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
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let key = "agent-shared-skills:\(agentID)"
        guard client != nil, !pendingMutations.contains(key) else { return }
        let old = agents[index].sharedSkills ?? []
        var memberships = old
        if enabled { memberships.append(skillID) } else { memberships.removeAll { $0 == skillID } }
        memberships = Array(Set(memberships)).sorted()
        agents[index].sharedSkills = memberships
        optimisticMutation(
            key: key, update: {},
            rollback: { [self] in
                if let index = agents.firstIndex(where: { $0.id == agentID }) { agents[index].sharedSkills = old }
            },
            work: { client in
                let saved = try await client.updateAgent(
                    agentID, patch: ["sharedSkills": .array(memberships.map(JSONValue.string))])
                return { [self] in
                    if let index = agents.firstIndex(where: { $0.id == agentID }) {
                        agents[index].sharedSkills = saved.sharedSkills
                    }
                }
            })
    }
}
