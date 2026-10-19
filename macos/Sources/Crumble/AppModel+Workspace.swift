import apfelkern
import Foundation

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
        case .skills: loadSkillsPanel()
        case .tasks: loadTasksPanel()
        case .activity: loadActivityPanel()
        case .integrations: loadIntegrationsPanel()
        case .agent:
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

    private func loadSkillsPanel() {
        let mutationVersion = mutationRevision
        request { client in
            async let bots = client.agents()
            async let skills = client.sharedSkills()
            let (loadedBots, loadedSkills) = try await (bots, skills)
            return { [self] in
                guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
                agents = loadedBots
                sharedSkills = loadedSkills
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
        request { client in
            let feed = try await client.activityFeed()
            return { [self] in activities = feed.activities }
        }
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
