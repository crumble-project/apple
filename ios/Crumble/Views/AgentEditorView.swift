import apfelkern
import BotAvatar
import SwiftUI

struct AgentEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: AgentDraft

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      editorForm
      .formStyle(.grouped)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.errorText = ""
            model.agentDraft = nil
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(draft.isNew ? "Create" : "Save") { model.saveAgentEditor() }.disabled(
            model.loading)
        }
      }
      .navigationTitle(draft.isNew ? "New Agent" : "Edit Agent")
      .navigationBarTitleDisplayMode(.inline)
    }
    .confirmationDialog("Delete agent?", isPresented: $model.confirmingDelete) {
      Button("Delete", role: .destructive) { model.deleteSelected() }
    } message: {
      Text("The agent, its chat, memories and tasks will be removed.")
    }
  }
}

extension AgentEditorView {
  private var editorForm: some View {
    Form {
      avatarSection
      SheetError()
      Section {
        TextField("Agent name", text: $draft.name, prompt: Text("Agent name"))
          .accessibilityLabel("Agent name")
        TextField("Description", text: $draft.description, prompt: Text("What it helps with"))
        Toggle("Enabled", isOn: $draft.enabled)
      }
      modelSection
      inferenceSection
      Section {
        TextEditor(text: $draft.instructions)
          .font(.body)
          .frame(minHeight: 90)
      } header: {
        Text("Instructions")
      } footer: {
        Text("How the agent should behave in every chat.").foregroundStyle(.secondary)
      }
      capabilitiesSection
      integrationsSection
      skillsSection
      if !draft.isNew {
        Section {
          Button("Duplicate Agent") { model.duplicateSelected() }
          Button("Delete Agent…", role: .destructive) { model.confirmingDelete = true }
        }
      }
    }
  }

  private var avatarChoices: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(draft.avatarChoices, id: \.self) { seed in
          Button {
            draft.avatar = "bot:" + seed
          } label: {
            BotAvatarView(seed: seed, size: 36)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
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
          .frame(width: 44, height: 44)
      }
      .padding(.horizontal, 4)
    }
  }

  private var integrationsSection: some View {
    Section("Integrations") {
      let servers = model.usableServers(for: draft.agentID)
      if servers.isEmpty {
        Text("Add an MCP server under Integrations to use its tools here.").foregroundStyle(
          .secondary)
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

  private var avatarSection: some View {
    Section {
      VStack(spacing: 8) {
        BotAvatarView(
          seed: agentAvatarSeed(Agent(id: draft.agentID, avatar: draft.avatar)), size: 96,
          live: true)
        Text(draft.name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "New Agent").font(
          .title2.bold())
        avatarChoices
      }
      .frame(maxWidth: .infinity)
    }
  }

  private var modelSection: some View {
    Section {
      if model.providerChoices.isEmpty {
        TextField(
          "Provider name",
          text: Binding(get: { draft.provider }, set: { model.changeEditorProvider($0) })
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      } else {
        Picker(
          "Provider",
          selection: Binding(get: { draft.provider }, set: { model.changeEditorProvider($0) })
        ) {
          ForEach(model.providerChoices, id: \.self) { Text($0).tag($0) }
        }
      }
      HStack {
        TextField("Model ID", text: $draft.model, prompt: Text("Model ID"))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        if !model.models.isEmpty {
          Menu {
            ForEach(model.models, id: \.id) { summary in
              Button(summary.id) { draft.model = summary.id }
            }
          } label: {
            Image(systemName: "list.bullet")
          }
          .accessibilityLabel("Choose a model")
        }
      }
    } header: {
      Text("Model")
    } footer: {
      Text(model.modelHint).foregroundStyle(.secondary)
    }
  }

  private var inferenceSection: some View {
    Section {
      Picker("Reasoning", selection: $draft.thinking) {
        Text("Off").tag("off")
        Text("Minimal").tag("minimal")
        Text("Low").tag("low")
        Text("Medium").tag("medium")
        Text("High").tag("high")
        Text("Extra high").tag("xhigh")
        Text("Maximum").tag("max")
      }
      LabeledContent("Temperature") {
        TextField("Optional, 0–2", text: $draft.temperature)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .keyboardType(.decimalPad)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityLabel("Temperature, optional, from 0 to 2")
      }
      LabeledContent("Max output tokens") {
        TextField("Optional", text: $draft.maxOutput)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .keyboardType(.numberPad)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityLabel("Maximum output tokens, optional")
      }
    } header: {
      Text("Inference")
    } footer: {
      Text(
        """
        Reasoning controls how much deliberation the model uses. Temperature must be between 0 and 2; \
        max output tokens must be a positive integer.
        """
      )
      .foregroundStyle(.secondary)
    }
  }

  private var capabilitiesSection: some View {
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
      Text(
        """
        Memory lets the agent keep notes between chats; with shared memory it also recalls and keeps \
        notes every bot using \
        shared memory sees. Schedule tasks lets it save one-time and recurring tasks for itself, or for \
        a bot it is allowed \
        to message. Each task runs in that bot’s chat. When Message other bots is enabled, it can ask \
        the permitted bots \
        you select and relay their answers; bounded task delegation remains supported. Code mode has the agent write a \
        short script that calls its tools, so many tool calls take one step. Enabled tools run directly using the \
        integrations permitted in this profile.
        """
      )
      .foregroundStyle(.secondary)
    }
  }

  private var skillsSection: some View {
    Section {
      ForEach($draft.skills) { $skill in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            TextField("Skill name", text: $skill.name, prompt: Text("Skill name"))
              .labelsHidden()
              .fontWeight(.semibold)
            Button("Remove Skill", systemImage: "xmark") {
              draft.skills.removeAll { $0.id == skill.id }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
          }
          TextField(
            "Skill instructions", text: $skill.instructions,
            prompt: Text("What the agent should do"), axis: .vertical
          )
          .labelsHidden()
          .lineLimit(2...10)
          .foregroundStyle(.secondary)
        }
      }
      Button("Add Skill…") { draft.skills.append(Skill()) }
    } header: {
      Text("Skills")
    } footer: {
      Text(
        """
        Every bot follows the shared defaults, along with its personal skills. Manage shared skills and \
        bot assignments under Skills.
        """
      )
      .foregroundStyle(.secondary)
    }
  }

  private func membership(_ set: WritableKeyPath<AgentDraft, Set<String>>, _ id: String) -> Binding<
    Bool
  > {
    Binding(
      get: { draft[keyPath: set].contains(id) },
      set: { enabled in
        if enabled { draft[keyPath: set].insert(id) } else { draft[keyPath: set].remove(id) }
      }
    )
  }
}
