import apfelkern
import SwiftUI

struct SkillsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.sharedSkills.isEmpty && !model.agents.contains(where: { $0.skills?.isEmpty == false }) {
                    Text("No skills yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sharedSkills) { skill in
                    sharedRow(skill)
                }
                ForEach(model.agents) { agent in
                    ForEach(agent.skills ?? []) { skill in
                        personalRow(skill, agent: agent)
                    }
                }
            } footer: {
                Text("""
                    Default skills apply to every bot; edit their files on the server and restart it to load \
                    changes. Expand a shared skill to choose which bots use it.
                    """).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                    let usage = enabled.isEmpty ? "No bots enabled" : "Enabled for: " + enabled.joined(separator: ", ")
                    Text("Shared · " + usage)
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

    private func personalRow(_ skill: Skill, agent: Agent) -> some View {
        DisclosureGroup {
            Text(skill.instructions)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).fontWeight(.semibold)
                    Text("Only \(agent.name)").font(.caption).foregroundStyle(.secondary)
                }
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
