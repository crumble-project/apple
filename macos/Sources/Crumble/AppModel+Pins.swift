import apfelkern
import Foundation

/// A pinned row of the sidebar: a bot's chat or a group chat.
enum Conversation: Identifiable {
    case bot(Agent)
    case group(GroupChat)

    var route: Route {
        switch self {
        case .bot(let agent): .agent(agent.id)
        case .group(let group): .group(group.id)
        }
    }

    var id: Route { route }
}

extension AppModel {
    /// Pinned conversations, in pin order, which sit above the Bots and Group Chats sections.
    var pinnedConversations: [Conversation] {
        let all = agents.map(Conversation.bot) + groupChats.map(Conversation.group)
        return pinBoard.pins.split(all, route: \.route).pinned
    }

    var unpinnedAgents: [Agent] { pinBoard.pins.split(agents) { .agent($0.id) }.unpinned }

    var unpinnedGroups: [GroupChat] { pinBoard.pins.split(groupChats) { .group($0.id) }.unpinned }

    /// Every change is written whole and cut down to the conversations loaded here, so it waits for
    /// the account's pins, the bots, and the groups. Before then it would drop pins this app hasn't seen.
    var canChangePins: Bool { pinBoard.isLoaded && agentsLoaded && groupChatsLoaded }

    private var conversationRoutes: Set<Route> {
        Set(agents.map { .agent($0.id) } + groupChats.map { .group($0.id) })
    }

    func isPinned(_ route: Route) -> Bool { pinBoard.pins.contains(route) }

    func canPin(_ route: Route) -> Bool {
        canChangePins && pinBoard.pins.canPin(route, among: conversationRoutes)
    }

    func setPinned(_ route: Route, _ pinned: Bool) {
        let pins = pinBoard.pins
        changePins(
            pinned ? pins.pinning(route, among: conversationRoutes) : pins.unpinning(route, among: conversationRoutes))
    }

    /// A pin dropped on another takes its place, the way Messages' pins push each other aside.
    func movePin(_ route: Route, to target: Route) {
        changePins(pinBoard.pins.moving(route, to: target, among: conversationRoutes))
    }

    /// The bot list has loaded, so the account's pins can be read and changed.
    func loadPins(client: APIClient) {
        agentsLoaded = true
        pinBoard.refresh(client: client)
    }

    /// Reads the account's pins as the activity stream connects, since pins events aren't replayed,
    /// and returns the handler for the stream's pins events, which other apps' changes send.
    func followPins(client: APIClient, generation: Int) -> @Sendable ([String]) async -> Void {
        pinBoard.refresh(client: client)
        return { [self] keys in
            await MainActor.run {
                guard self.generation == generation else { return }
                pinBoard.receive(keys)
            }
        }
    }

    private func changePins(_ next: PinnedConversations) {
        guard canChangePins, let client else { return }
        pinBoard.change(next, client: client, onFailure: showNotice)
    }
}
