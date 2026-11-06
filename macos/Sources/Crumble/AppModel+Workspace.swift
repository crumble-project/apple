import apfelkern
import Foundation

extension AppModel: AvatarHost {}

extension AppModel {
    // MARK: Workspace panels

    func openPanel(_ panel: Route) {
        workspaceRoute = panel
        memoryDraft = nil
        taskDraft = nil
        mcpDraft = nil
        skillDraft = nil
        switch panel {
        case .memory: loadMemoryPanel()
        case .skills: reloadSkills()
        case .tasks: loadTasksPanel()
        case .activity: loadActivityPanel()
        case .avatars: break
        case .credentials, .logins:
            if let kind = panel.botSecretKind { loadBotSecrets(kind) }
        case .integrations: loadIntegrationsPanel()
        case .coding:
            loadGitHubApps()
            loadGitHubAccounts()
            loadAdmin()
        case .users: loadAdmin()
        case .passwordManagers, .webSearch, .judgeModel, .visionModel, .messageGateways, .eventRelay:
            loadConnectedServices(panel)
        case .agent, .group:
            break
        }
    }

    /// Routines and memories for the details panel beside a bot's chat.
    func loadAgentDetails(_ agentID: String) {
        let mutationVersion = mutationRevision
        request { client in
            async let schedules = client.schedules()
            async let memories = client.memories(agentID)
            let (loadedSchedules, loadedMemories) = try await (schedules, memories)
            return { [self] in
                guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
                self.schedules = loadedSchedules
                agentMemories[agentID] = loadedMemories
            }
        }
    }

    private func loadMemoryPanel() {
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
                guard memoryLoadVersion == version, mutationRevision == mutationVersion, pendingMutations.isEmpty
                else { return }
                agents = bots
                sharedMemories = sharedItems
                agentMemories = personal
            }
        }
    }

    private func loadTasksPanel() {
        let mutationVersion = mutationRevision
        request { client in
            let items = try await client.schedules()
            return { [self] in
                guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
                schedules = items
            }
        }
    }

    private func loadActivityPanel() {
        loadActivityFeed()
        if let client { changeBoard.refresh(client: client) }
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
            self?.loadMemoryPanel()
            self?.reloadSkills()
        }
    }

    func loadMoreChanges() {
        guard let client else { return }
        changeBoard.loadMore(client: client)
    }

    private func loadIntegrationsPanel() {
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
}
