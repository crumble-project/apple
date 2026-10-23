import apfelkern
import Foundation

extension AppModel {
    // MARK: Agent profile

    func createAgent() {
        var draft = AgentDraft(isNew: true, agentID: "")
        draft.shuffleAvatars()
        agentDraft = draft
        loadEditorData(provider: draft.provider)
    }

    func openEditor(agentID: String? = nil) {
        guard let agent = agents.first(where: { $0.id == (agentID ?? selectedAgentID) }) else { return }
        var draft = AgentDraft(isNew: false, agentID: agent.id)
        draft.name = agent.name
        draft.description = agent.description ?? ""
        draft.instructions = agent.instructions ?? ""
        draft.model = agent.model ?? ""
        draft.provider = agent.provider ?? ""
        draft.enabled = agent.enabled
        draft.avatar = "bot:" + agentAvatarSeed(agent)
        if let inference = agent.inference {
            draft.thinking = inference.thinkingLevel
            draft.temperature = inference.temperature.map { String($0) } ?? ""
            draft.maxOutput = inference.maxOutputTokens.map { String($0) } ?? ""
        }
        let tools = agent.tools ?? []
        draft.toolsMemory = tools.contains("memory")
        draft.toolsDelegate = tools.contains("delegate")
        draft.toolsSchedule = tools.contains("schedule")
        draft.toolsCodemode = tools.contains("codemode")
        draft.toolsCoding = tools.contains("coding")
        draft.toolsDesktop = tools.contains("desktop")
        draft.desktopProvider = agent.desktopModel?.provider ?? ""
        draft.desktopModel = agent.desktopModel?.model ?? ""
        draft.skills = agent.skills ?? []
        draft.sharedSkills = Set(agent.sharedSkills ?? [])
        draft.sharedMemory = agent.sharedMemory ?? false
        draft.delegates = Set(agent.delegates ?? [])
        draft.mcpServers = Set(agent.mcpServers ?? [])
        draft.shuffleAvatars()
        agentDraft = draft
        loadEditorData(provider: draft.provider)
    }

    private func loadEditorData(provider: String) {
        models = []
        let revision = mutationRevision
        request { client in
            async let servers = client.mcpServers()
            async let skills = client.sharedSkills()
            let (loadedServers, loadedSkills) = try await (servers, skills)
            return { [self] in
                guard mutationRevision == revision, pendingMutations.isEmpty else { return }
                mcpServers = loadedServers
                sharedSkills = loadedSkills
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

    func loadModels(_ provider: String) {
        request { client in
            let models = try await client.models(provider: provider)
            return { [self] in
                guard agentDraft?.provider == provider else { return }
                self.models = models
                if agentDraft?.model.isEmpty == true, let first = models.first { agentDraft?.model = first.id }
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
            providers.filter(\.configured).map(\.provider) + providers.filter { !$0.configured }.map(\.provider)
        let current = agentDraft?.provider ?? ""
        return ordered.contains(current) || current.isEmpty ? ordered : [current] + ordered
    }

    var modelHint: String {
        if let provider = providers.first(where: { $0.provider == agentDraft?.provider }), !provider.configured {
            return "Add an API key for this provider in Settings to load its models."
        }
        return models.isEmpty ? "Type a model ID." : "\(models.count) models available."
    }

    func saveAgentEditor() {
        guard let draft = agentDraft, let input = editorInput(for: draft) else { return }
        persistAgentEditor(draft, input: input)
    }

    private func editorInput(for draft: AgentDraft) -> Agent? {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorText = "Give your agent a name."
            return nil
        }
        var tools: [String] = []
        if draft.toolsMemory { tools.append("memory") }
        if draft.toolsDelegate { tools.append("delegate") }
        if draft.toolsSchedule { tools.append("schedule") }
        if draft.toolsCodemode { tools.append("codemode") }
        if draft.toolsCoding { tools.append("coding") }
        if draft.toolsDesktop { tools.append("desktop") }
        // Capabilities without a toggle here were set elsewhere; saving must not drop them.
        let toggled: Set = ["memory", "delegate", "schedule", "codemode", "coding", "desktop"]
        let stored = agents.first { $0.id == draft.agentID }?.tools ?? []
        tools += stored.filter { !toggled.contains($0) }
        if draft.skills.contains(where: {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty
                || $0.instructions.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            errorText = "Each skill needs a name and instructions."
            return nil
        }
        guard let inference = editorInference(for: draft) else { return nil }
        let delegates = draft.delegates.sorted()
        let servers = draft.mcpServers.sorted()
        let shared = draft.sharedSkills.filter { id in sharedSkills.contains { $0.id == id && !$0.isDefault } }.sorted()
        return Agent(
            name: name, description: draft.description.nilIfEmpty, instructions: draft.instructions.nilIfEmpty,
            avatar: draft.avatar, enabled: draft.enabled, provider: draft.provider.nilIfEmpty,
            model: draft.model.nilIfEmpty,
            tools: tools, delegates: delegates, skills: draft.skills,
            sharedSkills: shared, sharedMemory: draft.sharedMemory, mcpServers: servers, inference: inference,
            desktopModel: desktopModel(for: draft))
    }

    private func persistAgentEditor(_ draft: AgentDraft, input: Agent) {
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
                let agent: Agent
                if isNew {
                    agent = try await client.createAgent(input)
                } else {
                    agent = try await client.updateAgent(
                        id,
                        patch: try self.editorPatch(for: draft, input: input))
                }
                return { [self] in
                    reconcileAgentEditor(agent, replacing: id, isNew: isNew, originalRoute: originalRoute)
                }
            })
    }

    private func reconcileAgentEditor(_ agent: Agent, replacing id: String, isNew: Bool, originalRoute: Route?) {
        if let index = agents.firstIndex(where: { $0.id == id }) {
            let lastMessage = agents[index].lastMessage
            agents[index] = agent
            agents[index].lastMessage = agent.lastMessage ?? lastMessage
        }
        if isNew, route == originalRoute, agentDraft == nil {
            selectAgent(agent.id)
        }
    }

    private func editorPatch(for draft: AgentDraft, input: Agent) throws -> [String: JSONValue] {
        [
            "name": .string(input.name), "description": .string(draft.description),
            "instructions": .string(draft.instructions),
            "provider": .string(draft.provider), "model": .string(draft.model),
            "avatar": .string(draft.avatar),
            "enabled": .bool(draft.enabled),
            "tools": .array((input.tools ?? []).map(JSONValue.string)),
            "skills": try JSONValue(encoding: draft.skills),
            "sharedSkills": .array((input.sharedSkills ?? []).map(JSONValue.string)),
            "sharedMemory": .bool(draft.sharedMemory),
            "mcpServers": .array((input.mcpServers ?? []).map(JSONValue.string)),
            "delegates": .array((input.delegates ?? []).map(JSONValue.string)),
            "inference": try JSONValue(encoding: input.inference),
            // Null clears an override, so the bot's desktop jobs use its own model again.
            "desktopModel": try input.desktopModel.map { try JSONValue(encoding: $0) } ?? .null
        ]
    }

    /// Both fields set picks a model for desktop jobs; both empty means the bot's own model.
    private func desktopModel(for draft: AgentDraft) -> DesktopModel? {
        let provider = draft.desktopProvider.trimmingCharacters(in: .whitespaces)
        let model = draft.desktopModel.trimmingCharacters(in: .whitespaces)
        return provider.isEmpty || model.isEmpty ? nil : DesktopModel(provider: provider, model: model)
    }

    private func editorInference(for draft: AgentDraft) -> Inference? {
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
                    if let index = agents.firstIndex(where: { $0.id == temporaryID }) { agents[index] = agent }
                    if route == originalRoute, agentDraft == nil {
                        selectAgent(agent.id)
                        openEditor()
                    }
                }
            })
    }

    func deleteSelected() {
        let id = agentDraft?.agentID ?? selectedAgentID
        guard !id.hasPrefix("pending:"), let index = agents.firstIndex(where: { $0.id == id }) else { return }
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
                    clearSelectedChat()
                    if case .agent = route {
                        if let next = agents.first { selectAgent(next.id) } else { route = nil }
                    }
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
