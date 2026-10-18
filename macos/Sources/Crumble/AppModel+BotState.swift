import apfelkern
import Foundation

extension AppModel {
    func updateRunningBot(_ id: String, running: Bool) {
        guard !id.isEmpty else { return }
        if running {
            runningAgentIDs.insert(id)
        } else {
            runningAgentIDs.remove(id)
        }
    }

    func stopFollowingBackgroundChat(_ id: String) {
        backgroundChats.removeValue(forKey: id)?.task.cancel()
    }

    func resetRunningBots() {
        for chat in backgroundChats.values { chat.task.cancel() }
        backgroundChats.removeAll()
        runningAgentIDs.removeAll()
    }

    func followBackgroundChat(_ agentID: String) {
        guard backgroundChats[agentID] == nil, let client else { return }
        let connection = generation
        let watchID = UUID()
        let task = Task {
            var backoff = Duration.milliseconds(500)
            while !Task.isCancelled, generation == connection {
                do {
                    try await client.chatEvents(agentID) { payload in
                        guard let incoming = try? JSONDecoder().decode(ChatSnapshot.self, from: Data(payload.utf8)),
                            incoming.agentId == agentID else { return }
                        await MainActor.run {
                            guard self.generation == connection,
                                self.backgroundChats[agentID]?.id == watchID,
                                !Task.isCancelled else { return }
                            self.updateRunningBot(agentID, running: incoming.isRunning)
                            if !incoming.isRunning { self.stopFollowingBackgroundChat(agentID) }
                        }
                    }
                } catch {
                    guard !Task.isCancelled, generation == connection,
                        backgroundChats[agentID]?.id == watchID else { return }
                    if let error = error as? APIError, error.statusCode == 404 {
                        updateRunningBot(agentID, running: false)
                        stopFollowingBackgroundChat(agentID)
                        return
                    }
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(8))
            }
        }
        backgroundChats[agentID] = (watchID, task)
    }
}
