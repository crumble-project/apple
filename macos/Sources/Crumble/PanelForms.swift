import apfelkern
import BotAvatar
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

struct AutomationFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AutomationDraft

    var body: some View {
        Form {
            let error = model.automationBoard.saveError
            if !error.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            AutomationFormSections(
                draft: $draft, agents: model.agents, capabilities: model.capabilities,
                sources: model.connectedServices.eventSources.sources,
                sourcesLoaded: model.connectedServices.eventSources.isLoaded,
                eventRelayURL: model.client?.webSettingsURL(.eventRelay))
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .toolbar {
            SheetActions(
                onCancel: model.automationBoard.closeDraft, onSave: model.saveAutomation, saveDisabled: false)
        }
    }
}

private struct AutomationSheet: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    private var draft: Binding<AutomationDraft?> {
        let board = model.automationBoard
        return Binding(
            get: { active ? board.draft : nil },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    func body(content: Content) -> some View {
        content.sheet(item: draft) { AutomationFormView(draft: sheetBinding(draft, for: $0)) }
    }
}

extension View {
    func automationSheet(active: Bool) -> some View {
        modifier(AutomationSheet(active: active))
    }
}

struct SkillFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SkillDraft

    var body: some View {
        Form {
            SheetError()
            Section {
                scopeField
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                    .limited($draft.name, by: SkillLimits.name)
                TextEditor(text: $draft.instructions).frame(minHeight: 120)
                    .limited($draft.instructions, by: SkillLimits.instructions)
            } header: {
                Text(draft.personal ? "Bot Skill" : "Shared Skill")
            } footer: {
                Text(
                    draft.personal
                        ? "This bot follows these instructions in every chat."
                        : "Bots that use this skill follow these instructions."
                ).foregroundStyle(.secondary)
            }
            if !draft.personal { SkillUsedBySection(selected: $draft.usedBy) }
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

    @ViewBuilder private var scopeField: some View {
        if draft.skillID.isEmpty {
            Picker(
                "Available to",
                selection: Binding(
                    get: { draft.agentID },
                    set: {
                        draft.agentID = $0
                        draft.personal = $0 != nil
                        if $0 != nil { draft.usedBy = [] }
                    })
            ) {
                Text("Every bot (shared)").tag(String?.none)
                ForEach(model.agents) { agent in
                    Text(agent.name).tag(Optional(agent.id))
                }
            }
        } else if draft.personal, let agent = model.agents.first(where: { $0.id == draft.agentID }) {
            LabeledContent("Bot", value: agent.name)
        }
    }
}
