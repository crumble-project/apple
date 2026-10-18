import SwiftUI

private struct SheetActions: ToolbarContent {
    let onCancel: () -> Void
    let onSave: () -> Void
    let saveDisabled: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        ToolbarItem(placement: .confirmationAction) { Button("Save", action: onSave).disabled(saveDisabled) }
    }
}

struct MemoryFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: MemoryDraft

    var body: some View {
        Form {
            SheetError()
            if draft.memoryID.isEmpty {
                Picker("Remembered by", selection: $draft.agentID) {
                    Text("Shared").tag(String?.none)
                    ForEach(model.agents) { agent in
                        Text(agent.name).tag(Optional(agent.id))
                    }
                }
                Text(
                    draft.agentID == nil
                        ? "Shared memory is available to bots with shared memory enabled."
                        : "Personal memory is available only to this bot."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent(
                    "Owner",
                    value: draft.agentID.flatMap { ownerID in model.agents.first(where: { $0.id == ownerID })?.name }
                        ?? "Shared")
            }
            Section("Memory Entry") {
                TextEditor(text: $draft.content).frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            SheetActions(
                onCancel: {
                    model.errorText = ""
                    model.memoryDraft = nil
                }, onSave: model.saveMemory, saveDisabled: model.loading)
        }
    }
}

struct TaskFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: TaskDraft

    var body: some View {
        Form {
            SheetError()
            Section("Task") {
                Picker("Runs on", selection: $draft.agentID) {
                    ForEach(model.agents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                Toggle("Enabled", isOn: $draft.enabled)
            }
            Section("Prompt") {
                TextEditor(text: $draft.prompt).frame(minHeight: 80)
            }
            scheduleSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            SheetActions(
                onCancel: {
                    model.errorText = ""
                    model.taskDraft = nil
                }, onSave: model.saveTask, saveDisabled: model.loading)
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("Frequency", selection: $draft.repeats) {
                Text("Run once").tag(false)
                Text("Repeat").tag(true)
            }
            if draft.repeats {
                TextField("Cron expression", text: $draft.cron, prompt: Text("0 9 * * 1-5"))
            } else {
                DatePicker("Date", selection: $draft.runDate, displayedComponents: .date)
                DatePicker("Time", selection: $draft.runDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
            }
            TextField("Time zone", text: $draft.timezone, prompt: Text("UTC"))
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
}

struct MCPFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: MCPDraft

    var body: some View {
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
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextField("HTTP URL", text: $draft.url, prompt: Text("https://"))
                SecureField("Token", text: $draft.token, prompt: Text("Optional"))
                Toggle("Enabled", isOn: $draft.enabled)
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Leave the token empty for servers that use OAuth, then choose Sign In in the list after saving.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            SheetActions(
                onCancel: {
                    model.errorText = ""
                    model.mcpDraft = nil
                }, onSave: model.saveMCP, saveDisabled: model.loading)
        }
    }
}

struct SkillFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SkillDraft

    var body: some View {
        Form {
            SheetError()
            Section {
                if draft.personal {
                    if draft.skillID.isEmpty {
                        Picker("Bot", selection: Binding(get: { draft.agentID ?? "" }, set: { draft.agentID = $0 })) {
                            Text("Choose a bot").tag("")
                            ForEach(model.agents) { agent in
                                Text(agent.name).tag(agent.id)
                            }
                        }
                    } else if let agent = model.agents.first(where: { $0.id == draft.agentID }) {
                        LabeledContent("Bot", value: agent.name)
                    }
                }
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextEditor(text: $draft.instructions).frame(minHeight: 120)
            } header: {
                Text(draft.personal ? "Bot Skill" : "Shared Skill")
            } footer: {
                Text(
                    draft.personal
                        ? "This bot follows these instructions in every chat."
                        : "Bots that turn this skill on in their profile follow these instructions."
                ).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            SheetActions(
                onCancel: {
                    model.errorText = ""
                    model.skillDraft = nil
                }, onSave: model.saveSkill, saveDisabled: model.loading)
        }
    }
}
