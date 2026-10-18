import apfelkern
import Foundation

extension AppModel {
    /// Carries the entry's owner into the form so edits never depend on the active chat.
    func openMemoryForm(_ id: String, agentID: String? = nil) {
        let existing = memories(for: agentID).first { $0.id == id }
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
                mutateMemories(for: agent) { items in
                    if let index = items.firstIndex(where: { $0.id == provisionalID || $0.id == form.memoryID }) {
                        items[index] = provisional
                    } else {
                        items.append(provisional)
                    }
                }
            },
            rollback: { [self] in
                mutateMemories(for: agent) { items in
                    items.removeAll { $0.id == provisionalID }
                    if let old { items.append(old) }
                }
                if workspaceRoute == .memory, memoryDraft == nil { memoryDraft = form }
            },
            work: { client in
                let saved = isNew
                    ? try await client.addMemory(agent, content: content)
                    : try await client.updateMemory(agent, memoryID: form.memoryID, content: content)
                return { [self] in
                    mutateMemories(for: agent) { items in
                        if let index = items.firstIndex(where: { $0.id == provisionalID }) { items[index] = saved }
                    }
                }
            })
    }

    func deleteMemory(_ id: String, agentID: String? = nil) {
        let items = memories(for: agentID)
        let old = items.first { $0.id == id }
        let oldIndex = items.firstIndex { $0.id == id }
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
                mutateMemories(for: agentID) { items in
                    items.insert(old, at: min(oldIndex ?? items.count, items.count))
                }
            },
            work: { client in
                try await client.deleteMemory(agentID, memoryID: id)
                return nil
            })
    }

    private func memories(for agentID: String?) -> [Memory] {
        if let agentID { return agentMemories[agentID] ?? [] }
        return sharedMemories
    }

    private func mutateMemories(for agentID: String?, update: (inout [Memory]) -> Void) {
        if let agentID {
            var items = agentMemories[agentID] ?? []
            update(&items)
            agentMemories[agentID] = items
        } else {
            update(&sharedMemories)
        }
    }
}
