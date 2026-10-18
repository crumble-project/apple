import SwiftUI

struct AgentEditorView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AgentDraft

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(spacing: 8) {
                    BotAvatarView(seed: agentAvatarSeed(Agent(id: draft.agentID, avatar: draft.avatar)), size: 96, live: true)
                    Text(draft.name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "New Agent").font(.title2.bold())
                    HStack(spacing: 6) {
                        ForEach(draft.avatarChoices, id: \.self) { seed in
                            Button {
                                draft.avatar = "bot:" + seed
                            } label: {
                                BotAvatarView(seed: seed, size: 36)
                                    .padding(3)
                                    .overlay {
                                        if draft.avatar == "bot:" + seed {
                                            RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Choose this avatar")
                        }
                        Button("More Avatars", systemImage: "shuffle") { draft.shuffleAvatars() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("More avatars")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            SheetError()
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextField("Description", text: $draft.description, prompt: Text("What it helps with"))
                TextField("Folder", text: $draft.folder, prompt: Text("Personal"))
                Toggle("Enabled", isOn: $draft.enabled)
            }
            Section {
                if model.providerChoices.isEmpty {
                    TextField("Provider", text: Binding(get: { draft.provider }, set: { model.changeEditorProvider($0) }))
                } else {
                    Picker("Provider", selection: Binding(get: { draft.provider }, set: { model.changeEditorProvider($0) })) {
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
            Section {
                TextEditor(text: $draft.instructions)
                    .font(.body)
                    .frame(minHeight: 90)
            } header: {
                Text("Instructions")
            } footer: {
                Text("How the agent should behave in every chat.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Memory", isOn: $draft.toolsMemory)
                if draft.toolsMemory {
                    Toggle("Use shared memory", isOn: $draft.sharedMemory).padding(.leading, 16)
                }
                Toggle("Schedule tasks", isOn: $draft.toolsSchedule)
                Toggle("Message other bots", isOn: $draft.toolsDelegate)
                if draft.toolsDelegate {
                    ForEach(model.agents.filter { $0.id != draft.agentID }) { agent in
                        Toggle(agent.name, isOn: membership(\.delegates, agent.id)).padding(.leading, 16)
                    }
                }
                Toggle("Code mode", isOn: $draft.toolsCodemode)
            } header: {
                Text("Capabilities")
            } footer: {
                Text("Memory lets the agent keep notes between chats; with shared memory it also recalls and keeps notes every bot using shared memory sees. Schedule tasks lets it save one-time and recurring tasks for itself, or for a bot it is allowed to message. Each task runs in that bot’s chat. When Message other bots is enabled, it can ask the permitted bots you select and relay their answers; bounded task delegation remains supported. Code mode has the agent write a short script that calls its tools, so many tool calls take one step; approvals still apply to each call.")
                    .foregroundStyle(.secondary)
            }
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
            Section {
                ForEach($draft.skills) { $skill in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Skill name", text: $skill.name, prompt: Text("Skill name"))
                                .labelsHidden()
                                .fontWeight(.semibold)
                            Button("Remove Skill", systemImage: "xmark") { draft.skills.removeAll { $0.id == skill.id } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                        TextField("Skill instructions", text: $skill.instructions, prompt: Text("What the agent should do"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(2...10)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Add Skill…") { draft.skills.append(Skill()) }
                ForEach(model.sharedSkills) { skill in
                    if skill.isDefault {
                        DisclosureGroup {
                            Text(skill.instructions)
                                .textSelection(.enabled)
                            if let path = skill.path, !path.isEmpty {
                                Text("Source: \(path)").font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Text(skill.name)
                                Spacer()
                                Text("Default · Every bot").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Toggle(isOn: membership(\.sharedSkills, skill.id)) {
                            Text(skill.name)
                            Text("Shared skill")
                        }
                    }
                }
            } header: {
                Text("Skills")
            } footer: {
                Text("Every bot follows the shared defaults, along with its personal skills and the optional shared skills you turn on. Manage shared skills under Skills.")
                    .foregroundStyle(.secondary)
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
                Button(draft.isNew ? "Create" : "Save") { model.saveAgentEditor() }.disabled(model.loading)
            }
        }
        .confirmationDialog("Delete agent?", isPresented: $model.confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("The agent, its chat, memories and tasks will be removed.")
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
