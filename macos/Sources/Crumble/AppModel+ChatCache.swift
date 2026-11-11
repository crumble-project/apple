import apfelkern

/// A bot's chat as the owner last saw it.
struct CachedChat {
    var messages: [Message]
    var hasMore: Bool
    var oldestEntryID: String
}

extension AppModel {
    /// Only confirmed rows are kept: unsent ones live in the delivery queue and come back from there.
    func rememberSelectedChat() {
        guard !selectedAgentID.isEmpty, snapshot != nil else { return }
        chatCache[selectedAgentID] = CachedChat(
            messages: messages.filter { $0.deliveryState == .confirmed }, hasMore: hasMore,
            oldestEntryID: oldestEntryID)
    }
}
