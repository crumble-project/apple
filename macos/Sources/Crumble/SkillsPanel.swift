import apfelkern
import SwiftUI

struct SkillsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            sharedSection
            personalSections
        }
        .formStyle(.grouped)
    }

    private var sharedSection: some View {
        Section {
            if model.sharedSkills.isEmpty {
                Text("No shared skills yet.").foregroundStyle(.secondary)
            }
            ForEach(model.sharedSkills) { skill in
                sharedRow(skill)
            }
        } header: {
            Text("Shared")
        } footer: {
            Text("""
                Defaults apply to every bot. Assign optional shared skills to bots here. \
                Edit default files on the server and restart it to load changes.
                """).foregroundStyle(.secondary)
        }
    }

    private func sharedRow(_ skill: SharedSkill) -> some View {
        DisclosureGroup {
            Text(skill.instructions)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let path = skill.path, !path.isEmpty {
                Text("Source: \(path)").font(.caption).foregroundStyle(.secondary)
            }
            if !skill.isDefault {
                Divider()
                Text("Assign to bots").font(.caption.weight(.medium))
                ForEach(model.agents) { agent in
                    Toggle(
                        agent.name,
                        isOn: Binding(
                            get: { agent.sharedSkills?.contains(skill.id) == true },
                            set: { model.setSharedSkill(skill.id, for: agent.id, enabled: $0) }
                        )
                    )
                    .disabled(model.pendingMutations.contains("agent-shared-skills:\(agent.id)"))
                }
            }
        } label: {
            sharedLabel(skill)
        }
    }

    private func sharedLabel(_ skill: SharedSkill) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).fontWeight(.semibold)
                if skill.isDefault {
                    Text("Default · Every bot").font(.caption).foregroundStyle(.secondary)
                } else {
                    let enabled = model.agents.filter { $0.sharedSkills?.contains(skill.id) == true }.map(\.name)
                    Text(enabled.isEmpty ? "No bots enabled" : "Enabled for: " + enabled.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !skill.isDefault {
                Button("Edit") { model.openSkillForm(skill.id) }.disabled(skill.id.hasPrefix("pending-"))
                Button("Delete") { model.deleteSharedSkill(skill.id) }.disabled(skill.id.hasPrefix("pending-"))
            }
        }
    }

    private var personalSections: some View {
        ForEach(model.agents) { agent in
            Section {
                let skills = agent.skills ?? []
                if skills.isEmpty {
                    Text("No skills of its own.").foregroundStyle(.secondary)
                }
                ForEach(skills) { skill in
                    personalRow(skill, agent: agent)
                }
                Button("Add Skill…") { model.openPersonalSkillForm(agentID: agent.id) }
                    .disabled(model.pendingMutations.contains("agent-skills:\(agent.id)"))
            } header: {
                Text(agent.name)
            } footer: {
                Text("""
                    Instructions only \(agent.name) follows. Manage these skills here; \
                    shared skills are assigned above.
                    """).foregroundStyle(.secondary)
            }
        }
    }

    private func personalRow(_ skill: Skill, agent: Agent) -> some View {
        DisclosureGroup {
            Text(skill.instructions)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(skill.name).fontWeight(.semibold)
                Spacer()
                Button("Edit") {
                    model.openPersonalSkillForm(agentID: agent.id, skillID: skill.id.uuidString)
                }
                .disabled(model.pendingMutations.contains("agent-skills:\(agent.id)"))
                Button("Delete", role: .destructive) {
                    model.deletePersonalSkill(agentID: agent.id, skillID: skill.id.uuidString)
                }
                .disabled(model.pendingMutations.contains("agent-skills:\(agent.id)"))
            }
        }
    }
}
