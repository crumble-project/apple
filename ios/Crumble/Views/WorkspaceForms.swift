import apfelkern
import BotAvatar
import SwiftUI

/// The Cancel and Save buttons of a form sheet.
private struct SheetActions: ToolbarContent {
  let onCancel: () -> Void
  let onSave: () -> Void
  let saveDisabled: Bool

  var body: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) { Button(role: .cancel, action: onCancel) }
    ToolbarItem(placement: .confirmationAction) {
      Button(role: .confirm, action: onSave).disabled(saveDisabled)
    }
  }
}

struct MemoryFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: MemoryDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        if draft.memoryID.isEmpty {
          Picker("Remembered by", selection: $draft.agentID) {
            Text("Shared").tag(String?.none)
            ForEach(model.agents) { agent in
              Text(agent.name).tag(Optional(agent.id))
            }
          }
        }
        Section("Memory Entry") {
          TextEditor(text: $draft.content).frame(minHeight: 120)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Memory")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.memoryDraft = nil
            dismiss()
          }, onSave: model.saveMemory, saveDisabled: model.loading)
      }
    }
  }
}

struct AutomationFormView: View {
  @Environment(AppModel.self) private var model
  @Binding var draft: AutomationDraft

  var body: some View {
    NavigationStack {
      Form {
        let error = model.automationBoard.saveError
        if !error.isEmpty {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red).textSelection(.enabled)
          }
        }
        AutomationFormSections(
          draft: $draft, agents: model.agents, capabilities: model.capabilities,
          sources: model.connectedServices.eventSources.sources,
          sourcesLoaded: model.connectedServices.eventSources.isLoaded,
          eventRelayURL: model.client?.webSettingsURL(.eventRelay))
      }
      .formStyle(.grouped)
      .navigationTitle(draft.isNew ? "New Automation" : "Edit Automation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: model.automationBoard.closeDraft, onSave: model.saveAutomation, saveDisabled: false)
      }
    }
  }
}

struct SkillFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: SkillDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        Section {
          if draft.skillID.isEmpty {
            Picker(
              "Available to",
              selection: Binding(
                get: { draft.agentID },
                set: {
                  draft.agentID = $0
                  if $0 != nil { draft.usedBy = [] }
                })
            ) {
              Text("Every bot (shared)").tag(String?.none)
              ForEach(model.agents) { agent in
                Text(agent.name).tag(Optional(agent.id))
              }
            }
          }
          TextField("Skill name", text: $draft.name, prompt: Text("Skill name"))
            .accessibilityLabel(draft.agentID == nil ? "Shared skill name" : "Bot skill name")
            .limited($draft.name, by: SkillLimits.name)
          TextEditor(text: $draft.instructions).frame(minHeight: 120)
            .limited($draft.instructions, by: SkillLimits.instructions)
        } header: {
          Text(draft.agentID == nil ? "Shared Skill" : "Bot Skill")
        } footer: {
          Text(
            draft.agentID == nil
              ? "Bots that use this skill follow these instructions."
              : "This skill belongs to the selected bot and runs in its chat."
          )
            .foregroundStyle(.secondary)
        }
        if draft.agentID == nil { SkillUsedBySection(selected: $draft.usedBy) }
      }
      .formStyle(.grouped)
      .navigationTitle(draft.agentID == nil ? "Shared Skill" : "Bot Skill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.skillDraft = nil
            dismiss()
          }, onSave: model.saveSkill, saveDisabled: model.loading)
      }
    }
  }
}
