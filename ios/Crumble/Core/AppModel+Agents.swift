import apfelkern
import Foundation

extension AppModel {
  // MARK: Agent profile

  func createAgent() {
    var draft = AgentDraft(isNew: true, agentID: "")
    draft.delegates = Set(agents.map(\.id))
    agentDraft = draft
    loadEditorData(provider: draft.provider)
  }

  func openEditor(agentID: String? = nil) {
    guard let agent = agents.first(where: { $0.id == (agentID ?? selectedAgentID) }) else { return }
    let draft = AgentDraft(agent: agent)
    agentDraft = draft
    loadEditorData(provider: draft.provider)
  }

  /// The proposal in the bot editor, where saving approves the request.
  func openEditor(botRequest: BotRequest) {
    let draft = AgentDraft(botRequest: botRequest)
    agentDraft = draft
    loadEditorData(provider: draft.provider)
  }

  private func loadEditorData(provider: String) {
    models = []
    let revision = mutationRevision
    if let client { sharedSkillBoard.refresh(client: client) }
    request { client in
      let loadedServers = try await client.mcpServers()
      return { [self] in
        guard mutationRevision == revision, pendingMutations.isEmpty else { return }
        mcpServers = loadedServers
      }
    }
    loadProviders()
    loadModels(provider)
  }

  func loadProviders() {
    request { client in
      let providers = try await client.providers()
      return { [self] in
        self.providers = providers
        resumeProviderLogins()
      }
    }
  }

  /// Providers changed, so what they list and reach did too, as the web's `refreshProviders`.
  func refreshProviders() {
    loadProviders()
    if let provider = agentDraft?.provider { loadModels(provider) }
    if let client { connectedServices.refreshModelChoices(client: client) }
  }

  func loadModels(_ provider: String) {
    request { client in
      let models = try await client.models(provider: provider)
      return { [self] in
        guard agentDraft?.provider == provider else { return }
        self.models = models
        if agentDraft?.model.isEmpty == true, let first = models.first {
          agentDraft?.model = first.id
        }
      }
    }
  }

  func changeEditorProvider(_ provider: String) {
    agentDraft?.provider = provider
    agentDraft?.model = ""
    models = []
    loadModels(provider)
  }

  /// The server's providers, configured ones first, keeping the current choice.
  var providerChoices: [String] {
    let ordered =
      providers.filter(\.configured).map(\.provider)
      + providers.filter { !$0.configured }.map(\.provider)
    let current = agentDraft?.provider ?? ""
    return ordered.contains(current) || current.isEmpty ? ordered : [current] + ordered
  }

  var modelHint: String {
    if let provider = providers.first(where: { $0.provider == agentDraft?.provider }),
      !provider.configured {
      return "Add an API key for this provider in Settings to load its models."
    }
    return models.isEmpty ? "Type a model ID." : "\(models.count) models available."
  }

  private func editorInference(_ draft: AgentDraft) -> Inference? {
    var inference = Inference(thinkingLevel: draft.thinking.isEmpty ? "off" : draft.thinking)
    if !draft.temperature.isEmpty {
      guard let value = Double(draft.temperature), (0...2).contains(value) else {
        errorText = "Temperature must be between 0 and 2."
        return nil
      }
      inference.temperature = value
    }
    if !draft.maxOutput.isEmpty {
      guard let value = Int(draft.maxOutput), (1...1_000_000).contains(value) else {
        errorText = "Output limit must be between 1 and 1,000,000 tokens."
        return nil
      }
      inference.maxOutputTokens = value
    }
    return inference
  }

  private func agentInput(from draft: AgentDraft) -> Agent? {
    let name = draft.name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else {
      errorText = "Give your agent a name."
      return nil
    }
    if draft.isNew, draft.skills.contains(where: {
      $0.name.trimmingCharacters(in: .whitespaces).isEmpty
        || $0.instructions.trimmingCharacters(in: .whitespaces).isEmpty
    }) {
      errorText = "Each skill needs a name and instructions."
      return nil
    }
    guard let inference = editorInference(draft) else { return nil }
    let delegates = draft.delegates.sorted()
    let servers = draft.mcpServers.sorted()
    let shared = draft.sharedSkills.filter { id in
      sharedSkills.contains { $0.id == id && !$0.isDefault }
    }.sorted()
    // An open editor must not put back skills or assignments changed while it was open.
    let saved = draft.isNew ? nil : agents.first { $0.id == draft.agentID }
    return Agent(
      name: name, description: draft.description.nilIfEmpty,
      instructions: draft.instructions.nilIfEmpty,
      avatar: draft.avatar, enabled: draft.enabled, provider: draft.provider.nilIfEmpty,
      model: draft.model.nilIfEmpty,
      tools: draft.tools(
        keeping: draft.botRequest?.proposal.tools ?? agents.first { $0.id == draft.agentID }?.tools ?? []),
      webSearchProvider: draft.webSearchProvider,
      delegates: delegates, skills: saved?.skills ?? draft.skills,
      sharedSkills: saved?.sharedSkills ?? shared, sharedMemory: draft.sharedMemory, mcpServers: servers,
      inference: inference, desktopModel: draft.desktopModelChoice)
  }

  func saveAgentEditor() {
    guard let draft = agentDraft else { return }
    guard let input = agentInput(from: draft) else { return }
    if let request = draft.botRequest {
      errorText = ""
      approveBotRequest(request, editedTo: input)
      return
    }
    let isNew = draft.isNew
    let id = isNew ? "pending:" + newRequestID() : draft.agentID
    let old = agents.first { $0.id == id }
    var provisional = input
    provisional.id = id
    provisional.lastMessage = old?.lastMessage
    let originalRoute = route
    optimisticMutation(
      key: "agent:\(id)",
      update: { [self] in
        if let index = agents.firstIndex(where: { $0.id == id }) {
          agents[index] = provisional
        } else {
          agents.append(provisional)
        }
        agentDraft = nil
      },
      rollback: { [self] in
        if let old, let index = agents.firstIndex(where: { $0.id == id }) {
          agents[index] = old
        } else {
          agents.removeAll { $0.id == id }
        }
        if agentDraft == nil, route == originalRoute { agentDraft = draft }
      },
      work: { client in
        let agent = try await self.persistAgent(input, draft: draft, client: client)
        return { [self] in
          if let index = agents.firstIndex(where: { $0.id == id }) {
            let lastMessage = agents[index].lastMessage
            agents[index] = agent
            agents[index].lastMessage = agent.lastMessage ?? lastMessage
          }
          if isNew, route == originalRoute, agentDraft == nil {
            selectAgent(agent.id)
          }
        }
      })
  }

  private func persistAgent(_ input: Agent, draft: AgentDraft, client: APIClient) async throws -> Agent {
    if draft.isNew { return try await client.createAgent(input) }
    return try await client.updateAgent(
      draft.agentID,
      patch: [
        "name": .string(input.name), "description": .string(draft.description),
        "instructions": .string(draft.instructions),
        "provider": .string(draft.provider), "model": .string(draft.model),
        "avatar": try JSONValue(encoding: draft.avatar),
        "enabled": .bool(draft.enabled),
        "tools": .array((input.tools ?? []).map(JSONValue.string)),
        // Null puts the bot back on the account default.
        "webSearchProvider": input.webSearchProvider.map { .string($0.rawValue) } ?? .null,
        "sharedMemory": .bool(draft.sharedMemory),
        "mcpServers": .array((input.mcpServers ?? []).map(JSONValue.string)),
        "delegates": .array((input.delegates ?? []).map(JSONValue.string)),
        "inference": try JSONValue(encoding: input.inference),
        // Null clears an override, so the bot's desktop jobs use its own model again.
        "desktopModel": try input.desktopModel.map { try JSONValue(encoding: $0) } ?? .null
      ])
  }

  /// Loaded once per connection; a failed load leaves it unknown and the next refresh tries again.
  func loadCapabilities() {
    guard capabilities == nil, let client else { return }
    let connection = generation
    Task {
      guard let loaded = try? await client.capabilities(), generation == connection else { return }
      capabilities = loaded
    }
  }

  /// The Coding toggle appears when the server can run jobs. A bot that already has coding keeps
  /// the toggle if the server can't be asked, so the owner can still turn it off.
  func offersCoding(for draft: AgentDraft) -> Bool {
    (capabilities?.coding ?? false) || draft.toolsCoding
  }

  /// The Bot desktop toggle appears when the server has a desktop image. A bot that already has
  /// one keeps the toggle if the server can't be asked, so the owner can still turn it off.
  func offersDesktop(for draft: AgentDraft) -> Bool {
    (capabilities?.desktop ?? false) || draft.toolsDesktop
  }

  func duplicateSelected() {
    let id = agentDraft?.agentID ?? selectedAgentID
    guard var copy = agents.first(where: { $0.id == id }), !id.hasPrefix("pending:") else { return }
    let temporaryID = "pending:" + newRequestID()
    copy.id = temporaryID
    copy.name += " copy"
    copy.lastMessage = nil
    let originalRoute = route
    let originalDraft = agentDraft
    optimisticMutation(
      key: "agent:\(temporaryID)",
      update: { [self] in
        agents.append(copy)
        agentDraft = nil
      },
      rollback: { [self] in
        agents.removeAll { $0.id == temporaryID }
        if agentDraft == nil, route == originalRoute { agentDraft = originalDraft }
      },
      work: { client in
        let agent = try await client.duplicateAgent(id)
        return { [self] in
          if let index = agents.firstIndex(where: { $0.id == temporaryID }) {
            agents[index] = agent
          }
          if route == originalRoute, agentDraft == nil {
            selectAgent(agent.id)
            openEditor()
          }
        }
      })
  }

  func deleteSelected() {
    let id = agentDraft?.agentID ?? selectedAgentID
    guard !id.hasPrefix("pending:"), let index = agents.firstIndex(where: { $0.id == id }) else {
      return
    }
    let removed = agents[index]
    let memories = agentMemories[id]
    let wasSelected = selectedAgentID == id
    var routeAfterDeletion = route
    optimisticMutation(
      key: "agent:\(id)",
      update: { [self] in
        agents.removeAll { $0.id == id }
        agentMemories[id] = nil
        agentDraft = nil
        if wasSelected {
          clearDeletedSelection()
        }
        routeAfterDeletion = route
      },
      rollback: { [self] in
        agents.insert(removed, at: min(index, agents.count))
        agentMemories[id] = memories
        if wasSelected, route == routeAfterDeletion { selectAgent(id) }
      },
      work: { client in
        try await client.deleteAgent(id)
        return nil
      })
  }
}
