import Foundation

/// Finished replies the owner hasn't seen, by chat, as the web's tab title counts them. It lives only
/// as long as the session and the activity stream: the server keeps no read state.
public struct UnreadCounts: Equatable {
  private var chats: [Route: Int] = [:]

  public init() {}

  public var total: Int { chats.values.reduce(0, +) }

  public func count(_ route: Route) -> Int { chats[route] ?? 0 }

  public var badgeLabel: String? { total > 0 ? String(total) : nil }

  /// Call for a reply that isn't on screen; a bot's answer to a bot doesn't count.
  public mutating func add(_ event: ActivityEvent) {
    guard event.type == "reply", event.origin != "bot" else { return }
    chats[event.groupId.map(Route.group) ?? .agent(event.agentId), default: 0] += 1
  }

  public mutating func markSeen(_ route: Route?) {
    if let route { chats[route] = nil }
  }

  public mutating func clear() {
    chats = [:]
  }
}
