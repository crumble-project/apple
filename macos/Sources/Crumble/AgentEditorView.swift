import apfelkern
import BotAvatar
import SwiftUI

struct AgentEditorView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AgentDraft

    var body: some View {
        @Bindable var model = model
        Form {
            avatarSection
            SheetError()
            if let request = draft.botRequest { BotRequestEditorStatus(request: request) }
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextField("Description", text: $draft.description, prompt: Text("What it helps with"))
                Toggle("Enabled", isOn: $draft.enabled)
            }
            modelSection
            instructionsSection
            capabilitiesSection
            integrationsSection
            if !draft.isNew {
                BotSecretsSection(kind: .credential, agentID: draft.agentID)
                BotSecretsSection(kind: .login, agentID: draft.agentID)
            }
            if draft.isNew {
                Section("Skills") {
                    Text("Add this bot’s own skills and turn on shared skills after you create it.")
                        .foregroundStyle(.secondary)
                }
            } else {
                BotSkillsSection(title: "Skills", agentID: draft.agentID, agentName: draft.name)
                SharedSkillToggles(agentID: draft.agentID)
            }
            if !draft.isNew {
                Section {
                    Button("Duplicate Agent") { model.duplicateSelected() }
                    Button("Delete Agent…", role: .destructive) { model.confirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 680)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.errorText = ""
                    model.agentDraft = nil
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) { model.saveAgentEditor() }.disabled(saveDisabled)
            }
        }
        .botSecretSheets(active: true)
        .skillSheet(active: true)
        .task(id: draft.agentID) {
            if !draft.isNew {
                model.loadBotSecrets(agentID: draft.agentID)
                model.loadBotSkills(agentID: draft.agentID)
            }
        }
        .confirmationDialog("Delete agent?", isPresented: $model.confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("The agent, its chat, memories and tasks will be removed.")
        }
    }

    private var saveTitle: String {
        if draft.botRequest != nil { return "Approve" }
        return draft.isNew ? "Create" : "Save"
    }

    private var saveDisabled: Bool {
        guard let request = draft.botRequest else { return model.loading }
        return model.loading || !draft.canApprove || model.botRequestBoard.decision(for: request.id).sending
    }

    private var avatarSection: some View {
        Section {
            VStack(spacing: 8) {
                BotAvatarView(avatar: draft.avatar, size: 96, live: true)
                Text(draft.name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "New Agent").font(.title2.bold())
            }
            .frame(maxWidth: .infinity)
            BotAvatarEditor(value: $draft.avatar)
        }
    }

    private var modelSection: some View {
        Section {
            if model.providerChoices.isEmpty {
                TextField(
                    "Provider", text: Binding(get: { draft.provider }, set: { model.changeEditorProvider($0) }))
            } else {
                Picker(
                    "Provider", selection: Binding(get: { draft.provider }, set: { model.changeEditorProvider($0) })
                ) {
                    ForEach(model.providerChoices, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Model", text: $draft.model, prompt: Text("Model ID"))
                .textInputSuggestions {
                    ForEach(model.models, id: \.id) { summary in
                        Text(summary.id).textInputCompletion(summary.id)
                    }
                }
        } header: {
            Text("Model")
        } footer: {
            Text(model.modelHint).foregroundStyle(.secondary)
        }
    }

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $draft.instructions)
                .font(.body)
                .frame(minHeight: 90)
        } header: {
            Text("Instructions")
        } footer: {
            Text("How the agent should behave in every chat.").foregroundStyle(.secondary)
        }
    }

    private var integrationsSection: some View {
        Section("Integrations") {
            let servers = model.usableServers(for: draft.agentID)
            if servers.isEmpty {
                Text("Add an MCP server under Integrations to use its tools here.").foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                Toggle(isOn: membership(\.mcpServers, server.id)) {
                    Text(server.name)
                    if server.agentId != nil { Text("Only this agent") }
                }
                .disabled(!server.enabled)
            }
        }
    }

    private var capabilitiesSection: some View {
        Section("Capabilities") {
            Toggle(isOn: $draft.toolsMemory) {
                Text("Memory")
                Text("Keeps notes between chats.")
            }
            if draft.toolsMemory {
                Toggle(isOn: $draft.sharedMemory) {
                    Text("Use shared memory")
                    Text("Also recalls and keeps notes every bot using shared memory sees.")
                }
                .padding(.leading, 16)
            }
            Toggle(isOn: $draft.toolsSchedule) {
                Text("Schedule tasks")
                Text("Saves one-time and recurring tasks for itself or a bot it can message.")
            }
            Toggle(isOn: $draft.toolsDelegate) {
                Text("Message other bots")
                Text("Asks the bots you allow and relays their answers.")
            }
            if draft.toolsDelegate {
                ForEach(model.agents.filter { $0.id != draft.agentID }) { agent in
                    Toggle(agent.name, isOn: membership(\.delegates, agent.id)).padding(.leading, 16)
                }
            }
            Toggle(isOn: $draft.toolsCodemode) {
                Text("Code mode")
                Text("Writes a short script that calls its tools, so many tool calls take one step.")
            }
            workspaceToggles
        }
    }

    @ViewBuilder private var workspaceToggles: some View {
        if model.offersCoding(for: draft) {
            Toggle(isOn: $draft.toolsCoding) {
                Text("Coding")
                Text("Starts coding jobs that read, write, and run code in its workspace.")
            }
        }
        if model.offersDesktop(for: draft) {
            Toggle(isOn: $draft.toolsDesktop) {
                Text("Bot desktop")
                Text("Its own desktop with a browser, operated by desktop jobs. You can watch and take control.")
            }
            if draft.toolsDesktop { desktopModelFields.padding(.leading, 16) }
        }
    }

    @ViewBuilder private var desktopModelFields: some View {
        if model.providerChoices.isEmpty {
            TextField("Desktop job provider", text: $draft.desktopProvider, prompt: Text("Same as the agent"))
        } else {
            Picker("Desktop job provider", selection: $draft.desktopProvider) {
                Text("Same as the agent").tag("")
                ForEach(model.providerChoices, id: \.self) { Text($0).tag($0) }
            }
        }
        if !draft.desktopProvider.isEmpty {
            TextField("Desktop job model", text: $draft.desktopModel, prompt: Text("Model ID"))
        }
    }

    private func membership(_ set: WritableKeyPath<AgentDraft, Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: set].contains(id) },
            set: { enabled in
                if enabled { draft[keyPath: set].insert(id) } else { draft[keyPath: set].remove(id) }
            }
        )
    }
}
