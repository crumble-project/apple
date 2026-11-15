import apfelkern

/// A bot's chat as the owner last saw it.
struct CachedChat {
    var messages: [Message]
    var hasMore: Bool
    var oldestEntryID: String
}

extension AppModel {
    func prepareCachedHistory(for snapshot: ChatSnapshot) {
        guard self.snapshot == nil, let incoming = snapshot.messages else { return }
        let cached = chatCache[selectedAgentID]
        let identifiers = Set(cached?.messages.map(\.id) ?? [])
        let overlaps = incoming.contains { identifiers.contains($0.id) }
        if cached != nil, !overlaps { messages.removeAll { $0.deliveryState == .confirmed } }
        if !overlaps || (cached?.oldestEntryID.isEmpty ?? true) {
            hasMore = snapshot.hasMore ?? false
            oldestEntryID = snapshot.oldestEntryId ?? ""
        }
    }

    /// Only confirmed rows are kept: unsent ones live in the delivery queue and come back from there.
    func rememberSelectedChat() {
        guard !selectedAgentID.isEmpty, snapshot != nil else { return }
        chatCache[selectedAgentID] = CachedChat(
            messages: messages.filter { $0.deliveryState == .confirmed }, hasMore: hasMore,
            oldestEntryID: oldestEntryID)
    }
}
