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

  var conversations: [Conversation] {
    orderedConversations(agents.map(Conversation.bot) + groupChats.map(Conversation.group)) {
      conversationSummaries[$0.route]?.date
    }
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
