import apfelkern
import SwiftUI

struct SkillsPanel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      sharedSection
      ForEach(model.agents) { agent in
        personalSection(agent)
      }
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
      Text(
        """
        Defaults apply to every bot. Enable optional shared skills for each bot here. Edit default files \
        on the server and restart it to load changes.
        """
      ).foregroundStyle(.secondary)
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
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(skill.name).fontWeight(.semibold)
          sharedStatus(skill)
        }
        Spacer()
        if !skill.isDefault { sharedActions(skill) }
      }
    }
  }

  @ViewBuilder private func sharedStatus(_ skill: SharedSkill) -> some View {
    if skill.isDefault {
      Text("Default · Every bot").font(.caption).foregroundStyle(.secondary)
    } else {
      let enabled = model.agents.filter { $0.sharedSkills?.contains(skill.id) == true }.map(\.name)
      Text(enabled.isEmpty ? "No bots enabled" : "Enabled for: " + enabled.joined(separator: ", "))
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func sharedActions(_ skill: SharedSkill) -> some View {
    Menu {
      Section("Enable for bot") {
        ForEach(model.agents) { agent in
          Button {
            model.setSharedSkill(
              skill.id, for: agent.id,
              enabled: !(agent.sharedSkills?.contains(skill.id) ?? false))
          } label: {
            Label(
              agent.name,
              systemImage: agent.sharedSkills?.contains(skill.id) == true
                ? "checkmark.circle.fill" : "circle")
          }
          .disabled(model.pendingMutations.contains("agent-skill:\(agent.id):sharedSkills"))
        }
      }
      Button("Edit") { model.openSkillForm(skill.id) }
      Button("Delete", role: .destructive) { model.deleteSharedSkill(skill.id) }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .accessibilityLabel("Skill actions")
    .disabled(skill.id.hasPrefix("pending-") || model.pendingMutations.contains("skill:\(skill.id)"))
  }

  private func personalSection(_ agent: Agent) -> some View {
    Section {
      let skills = agent.skills ?? []
      if skills.isEmpty {
        Text("No skills of its own.").foregroundStyle(.secondary)
      }
      ForEach(skills) { skill in
        personalRow(skill, agent: agent)
      }
      Button("New Skill", systemImage: "plus") {
        model.openPersonalSkillForm(agentID: agent.id)
      }.disabled(model.pendingMutations.contains("agent-skill:\(agent.id):skills"))
    } header: {
      Text(agent.name)
    } footer: {
      Text("Instructions only \(agent.name) follows.").foregroundStyle(.secondary)
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
        Menu {
          Button("Edit") { model.openPersonalSkillForm(agentID: agent.id, skillID: skill.id.uuidString) }
          Button("Delete", role: .destructive) { model.deletePersonalSkill(skill.id.uuidString, from: agent.id) }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Skill actions")
        .disabled(model.pendingMutations.contains("agent-skill:\(agent.id):skills"))
      }
    }
  }
}
