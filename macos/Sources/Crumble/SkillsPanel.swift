import apfelkern
import SwiftUI

struct SkillsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.sharedSkills.isEmpty {
                    Text("No shared skills yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sharedSkills) { skill in
                    sharedRow(skill)
                }
            } footer: {
                Text("""
                    Default skills apply to every bot; edit their files on the server and restart it to load \
                    changes. Expand a shared skill to choose which bots use it.
                    """).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { agent in
                BotSkillsSection(title: agent.name, agentID: agent.id, agentName: agent.name)
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
}
