import Foundation

/// Conversations pinned above the list, like Messages, in the order they were pinned or arranged.
/// The account keeps the keys, so every app shows the same pins. Every change returns the whole new
/// list, cut down to conversations that exist, so a pin for a deleted chat leaves with the next change.
public struct PinnedConversations: Equatable, Sendable {
  /// Messages allows nine pins: three rows of three. The server refuses more.
  public static let limit = 9
  /// `agent:<id>` and `group:<id>`, first pin first.
  public private(set) var keys: [String]

  public init(keys: [String] = []) {
    self.keys = keys
  }

  public func contains(_ route: Route) -> Bool {
    Self.key(route).map(keys.contains) ?? false
  }

  /// Only chats can be pinned, and only while fewer than `limit` of the conversations that exist are.
  public func canPin(_ route: Route, among existing: Set<Route>) -> Bool {
    guard Self.key(route) != nil, !contains(route) else { return false }
    return existing.filter(contains).count < Self.limit
  }

  /// `route` pinned after the others.
  public func pinning(_ route: Route, among existing: Set<Route>) -> Self {
    guard canPin(route, among: existing), let key = Self.key(route) else { return self }
    return Self(keys: live(among: existing) + [key])
  }

  public func unpinning(_ route: Route, among existing: Set<Route>) -> Self {
    let key = Self.key(route)
    return Self(keys: live(among: existing).filter { $0 != key })
  }

  /// Pinned `route` moved into `target`'s place, the way a dragged pin pushes the others aside.
  public func moving(_ route: Route, to target: Route, among existing: Set<Route>) -> Self {
    var list = live(among: existing)
    guard let key = Self.key(route), let targetKey = Self.key(target), key != targetKey,
      let origin = list.firstIndex(of: key), let destination = list.firstIndex(of: targetKey)
    else { return Self(keys: list) }
    list.remove(at: origin)
    list.insert(key, at: destination)
    return Self(keys: list)
  }

  /// `items` split into the pinned ones, in pin order, and the rest, in their own order.
  public func split<Item>(_ items: [Item], route: (Item) -> Route) -> (pinned: [Item], unpinned: [Item]) {
    let order = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
    var pinned: [(Int, Item)] = []
    var unpinned: [Item] = []
    for item in items {
      if let key = Self.key(route(item)), let position = order[key] {
        pinned.append((position, item))
      } else {
        unpinned.append(item)
      }
    }
    return (pinned.sorted { $0.0 < $1.0 }.map(\.1), unpinned)
  }

  private func live(among existing: Set<Route>) -> [String] {
    let live = Set(existing.compactMap(Self.key))
    return keys.filter(live.contains)
  }

  /// A chat route as text, for the account and for dragging; nil for routes that can't be pinned.
  public static func key(_ route: Route) -> String? {
    switch route {
    case .agent(let id): "agent:\(id)"
    case .group(let id) where !id.hasPrefix("local:"): "group:\(id)"
    default: nil
    }
  }

  public static func route(key: String) -> Route? {
    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[1].isEmpty else { return nil }
    switch parts[0] {
    case "agent": return .agent(parts[1])
    case "group": return .group(parts[1])
    default: return nil
    }
  }
}
