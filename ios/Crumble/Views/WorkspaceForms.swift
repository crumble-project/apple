import apfelkern
import SwiftUI

/// The Cancel and Save buttons of a form sheet.
private struct SheetActions: ToolbarContent {
  let onCancel: () -> Void
  let onSave: () -> Void
  let saveDisabled: Bool

  var body: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
    ToolbarItem(placement: .confirmationAction) {
      Button("Save", action: onSave).disabled(saveDisabled)
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

struct TaskFormView: View {
  private var scheduleSection: some View {
    Section {
      Picker("Frequency", selection: $draft.repeats) {
        Text("Run once").tag(false)
        Text("Repeat").tag(true)
      }
      if draft.repeats {
        TextField("Cron expression", text: $draft.cron, prompt: Text("0 9 * * 1-5"))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      } else {
        DatePicker("Date", selection: $draft.runDate, displayedComponents: .date)
        DatePicker("Time", selection: $draft.runDate, displayedComponents: .hourAndMinute)
          .datePickerStyle(.compact)
      }
      TextField("Time zone", text: $draft.timezone, prompt: Text("UTC"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    } header: {
      Text("Schedule")
    } footer: {
      Text(
        draft.repeats
          ? "The cron expression runs in the selected time zone."
          : "Date and time are shown in the selected time zone."
      ).foregroundStyle(.secondary)
    }
    .environment(\.timeZone, TimeZone(identifier: draft.timezone) ?? .current)
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TaskDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        Section("Task") {
          Picker("Runs on", selection: $draft.agentID) {
            ForEach(model.agents) { agent in
              Text(agent.name).tag(agent.id)
            }
          }
          TextField("Task name", text: $draft.name, prompt: Text("Task name"))
            .accessibilityLabel("Task name")
          Toggle("Enabled", isOn: $draft.enabled)
        }
        Section("Prompt") {
          TextEditor(text: $draft.prompt).frame(minHeight: 80)
        }
        scheduleSection
      }
      .formStyle(.grouped)
      .navigationTitle("Task")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.taskDraft = nil
            dismiss()
          }, onSave: model.saveTask, saveDisabled: model.loading)
      }
    }
  }
}

struct MCPFormView: View {
  private var serverForm: some View {
    Form {
      SheetError()
      Section {
        if draft.serverID.isEmpty {
          Picker("Available to", selection: $draft.agentID) {
            Text("Every bot (shared)").tag(String?.none)
            ForEach(model.agents) { agent in
              Text(agent.name).tag(Optional(agent.id))
            }
          }
        }
        TextField("Server name", text: $draft.name, prompt: Text("Server name"))
          .accessibilityLabel("MCP server name")
        TextField("HTTP URL", text: $draft.url, prompt: Text("https://"))
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField("Token", text: $draft.token, prompt: Text("Token (optional)"))
        Toggle("Enabled", isOn: $draft.enabled)
      } header: {
        Text("MCP Server")
      } footer: {
        Text(
          "Leave the token empty for servers that use OAuth, then choose Sign In in the list after saving."
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: MCPDraft

  var body: some View {
    NavigationStack {
      serverForm
      .formStyle(.grouped)
      .navigationTitle("MCP Server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.mcpDraft = nil
            dismiss()
          }, onSave: model.saveMCP, saveDisabled: model.loading)
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
          TextField("Skill name", text: $draft.name, prompt: Text("Skill name"))
            .accessibilityLabel("Shared skill name")
          TextEditor(text: $draft.instructions).frame(minHeight: 120)
        } header: {
          Text(draft.agentID == nil ? "Shared Skill" : "Bot Skill")
        } footer: {
          Text(
            draft.agentID == nil
              ? "Enable this shared skill for bots from the Skills workspace."
              : "This skill belongs to the selected bot and runs in its chat."
          )
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Shared Skill")
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
