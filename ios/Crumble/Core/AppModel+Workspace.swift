import apfelkern
import Foundation

extension AppModel: BotListHost {}

extension AppModel {
  // MARK: Workspace panels

  func openPanel(_ panel: Route) {
    leaveGroup()
    route = panel
    memoryDraft = nil
    automationBoard.closeUnchangedDraft()
    mcpDraft = nil
    skillDraft = nil
    switch panel {
    case .memory:
      loadMemoryOverview()
    case .skills:
      reloadSkills()
    case .automations:
      loadAutomationsPanel()
    case .activity:
      loadActivityFeed()
      if let client { changeBoard.refresh(client: client) }
    case .avatars:
      break
    case .credentials, .logins:
      if let kind = panel.botSecretKind { loadBotSecrets(kind) }
    case .integrations:
      loadIntegrationOverview()
    case .coding:
      loadGitHubApps()
      loadGitHubAccounts()
      loadAdmin()
    case .users:
      loadAdmin()
    case .providers:
      loadProviders()
      loadPasswordManagers()
    case .passwordManagers, .webSearch, .judgeModel, .visionModel, .messageGateways, .eventRelay:
      loadConnectedServices(panel)
    case .agent, .group:
      break
    }
  }

  private func loadActivityFeed() {
    if let client { activityBoard.refresh(client: client) }
  }

  /// Both lists follow the page's filter; the Changes pill shows the board that tracks reverts.
  func showActivity(kind: ActivityKind?, botID: String?) {
    guard let client else { return }
    activityBoard.show(kind: kind, botID: botID, client: client)
    changeBoard.show(botID: botID, client: client)
  }

  func loadMoreActivity() {
    guard let client else { return }
    activityBoard.loadMore(client: client)
  }

  func saveAvatar() { avatarBoard.save(to: self) }

  func revertChange(_ change: LearnedChange) {
    guard let client else { return }
    changeBoard.revert(change, client: client) { [weak self] in
      self?.loadActivityFeed()
      self?.loadMemoryOverview()
      self?.reloadSkills()
    }
  }

  func loadMoreChanges() {
    guard let client else { return }
    changeBoard.loadMore(client: client)
  }

  private func loadIntegrationOverview() {
    let mutationVersion = mutationRevision
    request { client in
      async let bots = client.agents()
      async let servers = client.mcpServers()
      let (loadedBots, loadedServers) = try await (bots, servers)
      return { [self] in
        guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
        agents = loadedBots
        mcpServers = loadedServers
      }
    }
  }

  private func loadMemoryOverview() {
    memoryLoadVersion += 1
    let version = memoryLoadVersion
    let mutationVersion = mutationRevision
    request { client in
      let bots = try await client.agents()
      async let shared = client.memories(nil)
      let personal = try await withThrowingTaskGroup(of: (String, [Memory]).self) { group in
        for bot in bots {
          group.addTask { (bot.id, try await client.memories(bot.id)) }
        }
        var result: [String: [Memory]] = [:]
        for try await (id, memories) in group { result[id] = memories }
        return result
      }
      let sharedItems = try await shared
      return { [self] in
        guard memoryLoadVersion == version, mutationRevision == mutationVersion,
          pendingMutations.isEmpty
        else { return }
        agents = bots
        sharedMemories = sharedItems
        agentMemories = personal
      }
    }
  }

  /// Carries the entry's owner into the form so edits never depend on the active chat.
  func openMemoryForm(_ id: String, agentID: String? = nil) {
    let items = agentID.map { agentMemories[$0] ?? [] } ?? sharedMemories
    let existing = items.first { $0.id == id }
    memoryDraft = MemoryDraft(memoryID: id, content: existing?.content ?? "", agentID: agentID)
  }

  func saveMemory() {
    guard let form = memoryDraft else { return }
    let agent = form.agentID
    let content = form.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      errorText = "Memory content is required."
      return
    }
    let isNew = form.memoryID.isEmpty
    let provisionalID = isNew ? "pending-memory-" + newRequestID() : form.memoryID
    let provisional = Memory(id: provisionalID, content: content, createdAt: nil)
    let old = memories(for: agent).first { $0.id == form.memoryID }
    memoryDraft = nil
    optimisticMutation(
      key: "memory:\(provisionalID)",
      update: { [self] in
        replaceMemory(provisional, replacing: form.memoryID, for: agent)
      },
      rollback: { [self] in
        var items = memories(for: agent)
        items.removeAll { $0.id == provisionalID }
        if let old { items.append(old) }
        setMemories(items, for: agent)
        if route == .memory, memoryDraft == nil { memoryDraft = form }
      },
      work: { client in
        let saved =
          isNew
          ? try await client.addMemory(agent, content: content)
          : try await client.updateMemory(agent, memoryID: form.memoryID, content: content)
        return { [self] in
          confirmMemory(saved, provisionalID: provisionalID, for: agent)
        }
      })
  }

  private func memories(for agentID: String?) -> [Memory] {
    if let agentID { return agentMemories[agentID] ?? [] }
    return sharedMemories
  }

  private func setMemories(_ items: [Memory], for agentID: String?) {
    if let agentID {
      agentMemories[agentID] = items
    } else {
      sharedMemories = items
    }
  }

  private func replaceMemory(_ memory: Memory, replacing id: String, for agentID: String?) {
    var items = memories(for: agentID)
    if let index = items.firstIndex(where: { $0.id == memory.id || $0.id == id }) {
      items[index] = memory
    } else {
      items.append(memory)
    }
    setMemories(items, for: agentID)
  }

  private func confirmMemory(_ saved: Memory, provisionalID: String, for agentID: String?) {
    var items = memories(for: agentID)
    guard let index = items.firstIndex(where: { $0.id == provisionalID }) else { return }
    items[index] = saved
    setMemories(items, for: agentID)
  }

  func deleteMemory(_ id: String, agentID: String? = nil) {
    let old = memories(for: agentID).first { $0.id == id }
    let oldIndex = memories(for: agentID).firstIndex { $0.id == id }
    optimisticMutation(
      key: "memory:\(id)",
      update: { [self] in
        if let agentID {
          agentMemories[agentID]?.removeAll { $0.id == id }
        } else {
          sharedMemories.removeAll { $0.id == id }
        }
      },
      rollback: { [self] in
        guard let old else { return }
        var items = memories(for: agentID)
        items.insert(old, at: min(oldIndex ?? items.count, items.count))
        setMemories(items, for: agentID)
      },
      work: { client in
        try await client.deleteMemory(agentID, memoryID: id)
        return nil
      })
  }

  /// Automations and memories for the details panel beside a bot's chat.
  func loadAgentDetails(_ agentID: String) {
    if let client {
      automationBoard.refresh(client: client)
      connectedServices.eventSources.refresh(client: client)
    }
    let mutationVersion = mutationRevision
    request { client in
      let loadedMemories = try await client.memories(agentID)
      return { [self] in
        guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
        agentMemories[agentID] = loadedMemories
      }
    }
  }

  /// The failed-turn link.
  func openProviderSettings() {
    openPanel(.providers)
  }
}
