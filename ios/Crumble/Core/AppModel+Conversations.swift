import apfelkern
import Foundation

/// A row of the conversation list: a bot's chat or a group chat.
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
  private static let summaryHistory = 30

  /// Every conversation, the latest first.
  private var allConversations: [Conversation] {
    orderedConversations(agents.map(Conversation.bot) + groupChats.map(Conversation.group)) {
      conversationSummaries[$0.route]?.date
    }
  }

  private var pins: PinnedConversations { pinBoard.pins }

  /// Pinned conversations, in pin order, which sit above the list instead of in it.
  var pinnedConversations: [Conversation] { pins.split(allConversations, route: \.route).pinned }

  /// The list under the pins, the latest first.
  var conversations: [Conversation] { pins.split(allConversations, route: \.route).unpinned }

  private var conversationRoutes: Set<Route> {
    Set(agents.map { .agent($0.id) } + groupChats.map { .group($0.id) })
  }

  /// Pins change only once the account's pins and both conversation lists are known.
  private var pinsEditable: Bool { pinBoard.isLoaded && botsLoaded && groupsLoaded }

  func isPinned(_ route: Route) -> Bool { pins.contains(route) }

  func canPin(_ route: Route) -> Bool { pinsEditable && pins.canPin(route, among: conversationRoutes) }

  func setPinned(_ route: Route, _ pinned: Bool) {
    let routes = conversationRoutes
    changePins(pinned ? pins.pinning(route, among: routes) : pins.unpinning(route, among: routes))
  }

  /// A conversation dragged onto a pin: a pin trades places with it, and an unpinned chat is pinned there.
  func dropOnPin(_ route: Route, target: Route) {
    let routes = conversationRoutes
    var next = pins
    if !next.contains(route) {
      guard canPin(route) else { return }
      next = next.pinning(route, among: routes)
    }
    changePins(next.moving(route, to: target, among: routes))
  }

  private func changePins(_ next: PinnedConversations) {
    guard pinsEditable, let client else { return }
    pinBoard.change(next, client: client) { [weak self] in self?.showNotice($0) }
  }

  /// One short read per chat, because the lists carry no time and group chats no preview.
  func loadConversationSummaries() {
    guard let client else { return }
    let generation = generation
    let bots = agents.map(\.id)
    let groups = groupChats.map(\.id).filter { !$0.hasPrefix("local:") }
    Task {
      let found = await withTaskGroup(of: (Route, ConversationSummary?).self) { tasks in
        for id in bots {
          tasks.addTask {
            let history = try? await client.chatHistory(id, before: "", limit: Self.summaryHistory)
            return (.agent(id), ConversationSummary(messages: history?.messages ?? []))
          }
        }
        for id in groups {
          tasks.addTask {
            let history = try? await client.groupChatHistory(id, before: "", limit: Self.summaryHistory)
            return (.group(id), ConversationSummary(messages: history?.messages ?? []))
          }
        }
        var summaries: [Route: ConversationSummary] = [:]
        for await (route, summary) in tasks { summaries[route] = summary }
        return summaries
      }
      guard self.generation == generation else { return }
      conversationSummaries.merge(found) { current, read in
        (current.date ?? .distantPast) > (read.date ?? .distantPast) ? current : read
      }
    }
  }

  /// Leaving a chat is when the list can move it, with what was just said.
  func noteChatLeft(_ route: Route?) {
    guard let route, route.isChat, let summary = ConversationSummary(messages: messages) else { return }
    conversationSummaries[route] = summary
  }

  func noteConversationMoved(_ route: Route, preview: String?) {
    let current = conversationSummaries[route]
    conversationSummaries[route] = ConversationSummary(
      date: .now, preview: preview ?? current?.preview ?? "")
  }
}
