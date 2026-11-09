import apfelkern
import BotAvatar
import SwiftUI

struct AgentEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: AgentDraft
  @State var showingDesktop = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      editorForm
        // Here and not on the list row, which unloads once the cover hides it and would end the cover.
        .fullScreenCover(isPresented: $showingDesktop) { BotDesktopView(agentID: draft.agentID) }
      .formStyle(.grouped)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) {
            model.errorText = ""
            model.agentDraft = nil
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if draft.botRequest != nil {
            Button("Approve") { model.saveAgentEditor() }.disabled(saveDisabled)
          } else {
            Button(role: .confirm) { model.saveAgentEditor() }.disabled(saveDisabled)
          }
        }
      }
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
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
      Text("The agent, its chat, memories and automations will be removed.")
    }
  }
}

extension AgentEditorView {
  private var navigationTitle: String {
    if draft.botRequest != nil { return "Edit Bot Proposal" }
    return draft.isNew ? "New Agent" : "Edit Agent"
  }

  private var saveDisabled: Bool {
    guard let request = draft.botRequest else { return model.loading }
    return model.loading || !draft.canApprove || model.botRequestBoard.decision(for: request.id).sending
  }

  private var editorForm: some View {
    Form {
      desktopPreviewSection
      avatarSection
      SheetError()
      if let request = draft.botRequest { BotRequestEditorStatus(request: request) }
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
      if !draft.isNew {
        BotSecretsSection(kind: .credential, agentID: draft.agentID)
        BotSecretsSection(kind: .login, agentID: draft.agentID)
      }
      if draft.isNew {
        skillsSection
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
        BotAvatarPicker(value: $draft.avatar)
        Text(draft.name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "New Agent").font(
          .title2.bold())
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
      ReasoningField(
        levels: ThinkingLevel.available(for: draft.model, in: model.models), thinking: $draft.thinking)
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

  @ViewBuilder private var desktopPreviewSection: some View {
    let saved = model.agents.first { $0.id == draft.agentID }
    if let client = model.client, saved?.tools?.contains(DesktopJob.toolName) == true {
      Section("Desktop") {
        BotDesktopPreviewCard(
          preview: BotDesktopPreview(agentID: draft.agentID, client: client),
          open: { showingDesktop = true }
        )
        .listRowInsets(EdgeInsets())
      }
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
      DesktopModelField(provider: draft.desktopProvider, client: model.client, model: $draft.desktopModel)
    }
  }

  private var webSearchProviderPicker: some View {
    Picker(selection: $draft.webSearchProvider) {
      Text("Account default").tag(WebSearchProvider?.none)
      ForEach(WebSearchProvider.allCases) { Text($0.name).tag(WebSearchProvider?.some($0)) }
    } label: {
      Text("Web search provider")
      Text("Manage the default and Exa key in Settings → Web search.")
    }
  }

  private var capabilitiesSection: some View {
    Section {
      Toggle("Memory", isOn: $draft.toolsMemory)
      if draft.toolsMemory {
        Toggle("Use shared memory", isOn: $draft.sharedMemory).padding(.leading, 16)
      }
      Toggle(isOn: $draft.toolsWeb) {
        Text("Web search")
        Text("Searches the web and reads pages.")
      }
      if draft.toolsWeb { webSearchProviderPicker.padding(.leading, 16) }
      Toggle("Schedule automations", isOn: $draft.toolsSchedule)
      Toggle("Message other bots", isOn: $draft.toolsDelegate)
      if draft.toolsDelegate {
        ForEach(model.agents.filter { $0.id != draft.agentID }) { agent in
          Toggle(agent.name, isOn: membership(\.delegates, agent.id)).padding(.leading, 16)
        }
      }
      Toggle("Code mode", isOn: $draft.toolsCodemode)
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
      Toggle(isOn: $draft.toolsCreateBots) {
        Text("Create bots")
        Text("Asks you to approve new bots.")
      }
    } header: {
      Text("Capabilities")
    } footer: {
      Text(
        """
        Memory lets the agent keep notes between chats; with shared memory it also recalls and keeps \
        notes every bot using \
        shared memory sees. Schedule automations lets it save one-time and recurring automations for itself, or for \
        a bot it is allowed \
        to message. Each automation runs in that bot’s chat. When Message other bots is enabled, it can ask \
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
              .limited($skill.name, by: SkillLimits.name)
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
          .limited($skill.instructions, by: SkillLimits.instructions)
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
