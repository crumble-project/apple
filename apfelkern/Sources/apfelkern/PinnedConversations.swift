import Foundation

/// Conversations pinned above the list, like Messages, in the order they were pinned.
/// Pins live on this device and belong to one server, so a different server starts unpinned.
public struct PinnedConversations: Equatable {
  /// Messages allows nine pins: three rows of three.
  public static let limit = 9
  private static let storageKey = "crumble.pinnedConversations"
  /// Pinned route keys by server URL.
  private var keys: [String: [String]]
  private let defaults: UserDefaults?
  public var server: String

  public init(server: String = "", defaults: UserDefaults? = nil) {
    self.server = server
    self.defaults = defaults
    keys = defaults?.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
  }

  public static func == (left: Self, right: Self) -> Bool {
    left.server == right.server && left.keys == right.keys
  }

  private var current: [String] { keys[server] ?? [] }

  public func contains(_ route: Route) -> Bool {
    Self.key(route).map(current.contains) ?? false
  }

  /// Only chats can be pinned, and only while fewer than `limit` of the conversations that exist are.
  public func canPin(_ route: Route, among existing: Set<Route>) -> Bool {
    guard Self.key(route) != nil, !contains(route) else { return false }
    return existing.filter(contains).count < Self.limit
  }

  /// Pins `route` after the others. Pins whose conversation is gone are dropped on the way.
  public mutating func pin(_ route: Route, among existing: Set<Route>) {
    guard canPin(route, among: existing), let key = Self.key(route) else { return }
    let live = Set(existing.compactMap(Self.key))
    save(current.filter(live.contains) + [key])
  }

  /// Moves pinned `route` into `target`'s place, the way a dragged pin pushes the others aside.
  public mutating func move(_ route: Route, to target: Route) {
    guard let key = Self.key(route), let targetKey = Self.key(target), key != targetKey,
      let origin = current.firstIndex(of: key), let destination = current.firstIndex(of: targetKey)
    else { return }
    var list = current
    list.remove(at: origin)
    list.insert(key, at: destination)
    save(list)
  }

  public mutating func unpin(_ route: Route) {
    guard let key = Self.key(route) else { return }
    save(current.filter { $0 != key })
  }

  /// `items` split into the pinned ones, in pin order, and the rest, in their own order.
  public func split<Item>(_ items: [Item], route: (Item) -> Route) -> (pinned: [Item], unpinned: [Item]) {
    let order = Dictionary(current.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
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

  private mutating func save(_ list: [String]) {
    keys[server] = list.isEmpty ? nil : list
    defaults?.set(keys, forKey: Self.storageKey)
  }

  /// A chat route as text, for saving and for dragging; nil for routes that can't be pinned.
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
