import apfelkern
import SwiftUI

/// A bot's own skills, in the bot editor and the Skills workspace.
struct BotSkillsSection: View {
  @Environment(AppModel.self) private var model
  let title: String
  let agentID: String
  let agentName: String

  private var board: BotSkillBoard { model.botSkillBoard }

  var body: some View {
    Section {
      if let error = board.readError(agentID: agentID) {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
        Button("Retry") { model.loadBotSkills(agentID: agentID) }
      }
      if let error = board.errors[agentID] {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if !board.isLoaded(agentID: agentID), board.readError(agentID: agentID) == nil {
        // Bots can join the list while it is open, and nothing else reads theirs.
        ProgressView()
          .task(id: agentID) { model.loadBotSkills(agentID: agentID) }
      } else if board.isLoaded(agentID: agentID), board.skills(agentID: agentID).isEmpty {
        Text("No skills of its own yet.").foregroundStyle(.secondary)
      }
      ForEach(board.skills(agentID: agentID)) { skill in
        BotSkillRow(skill: skill, agentName: agentName)
      }
      Button("New Skill", systemImage: "plus") { model.openPersonalSkillForm(agentID: agentID) }
    } header: {
      Text(title)
    } footer: {
      Text("Only \(agentName) has these.").foregroundStyle(.secondary)
    }
  }
}

private struct BotSkillRow: View {
  @Environment(AppModel.self) private var model
  let skill: BotSkill
  let agentName: String
  @State private var deleting = false

  var body: some View {
    DisclosureGroup {
      Text(skill.instructions)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(skill.name).fontWeight(.semibold)
            if skill.pinned { Text("Pinned").font(.caption).foregroundStyle(.secondary) }
          }
          Text(skill.glimpse).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Menu {
          Button("Edit") { model.openPersonalSkillForm(agentID: skill.agentID, skillID: skill.id) }
          Button(skill.pinned ? "Unpin" : "Pin") {
            model.setBotSkillPinned(skill, pinned: !skill.pinned)
          }
          Divider()
          Button("Delete…", role: .destructive) { deleting = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
          .accessibilityLabel("Skill actions")
        .disabled(model.botSkillBoard.pending.contains(skill.id))
      }
    }
    .confirmationDialog("Delete \(skill.name)?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { model.deleteBotSkill(skill) }
    } message: {
      Text("\(agentName) loses this skill. This cannot be undone.")
    }
  }
}

/// Which shared skills a bot uses, applied as they change rather than with the editor's Save.
struct SharedSkillToggles: View {
  @Environment(AppModel.self) private var model
  let agentID: String

  var body: some View {
    let skills = model.sharedSkills.filter { !$0.isDefault }
    if let agent = model.agents.first(where: { $0.id == agentID }), !skills.isEmpty {
      Section {
        ForEach(skills) { skill in
          Toggle(
            skill.name,
            isOn: Binding(
              get: { agent.sharedSkills?.contains(skill.id) == true },
              set: { model.setSharedSkill(skill.id, for: agentID, enabled: $0) }
            )
          )
          .disabled(
            skill.id.hasPrefix("pending-")
              || model.pendingMutations.contains("agent-skill:\(agentID):sharedSkills"))
        }
      } header: {
        Text("Shared Skills")
      } footer: {
        Text("Turn a shared skill on for this bot. This applies right away.").foregroundStyle(.secondary)
      }
    }
  }
}

/// Presents the skill form. Only one presenter may be `active`: the root, or the bot editor
/// while it is open.
private struct SkillSheet: ViewModifier {
  @Environment(AppModel.self) private var model
  let active: Bool

  private var draft: Binding<SkillDraft?> {
    Binding(get: { active ? model.skillDraft : nil }, set: { model.skillDraft = $0 })
  }

  func body(content: Content) -> some View {
    content.sheet(item: draft) { SkillFormView(draft: sheetBinding(draft, for: $0)) }
  }
}

extension View {
  func skillSheet(active: Bool) -> some View {
    modifier(SkillSheet(active: active))
  }
}
