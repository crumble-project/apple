import Foundation

/// What a cross-bot Credentials or Logins page shows for its pill and search. Requests stay in their
/// own group on top, as on the web.
public struct BotSecretPage: Sendable {
  public struct Waiting: Identifiable, Sendable {
    public var bot: Agent
    public var request: BotSecretRequest
    public var id: String { bot.id + ":" + request.name }
  }

  public struct Group: Identifiable, Sendable {
    public var bot: Agent
    public var items: [BotSecret]
    /// Why nothing is listed, when loaded.
    public var note: String?
    public var error: String?
    public var id: String { bot.id }
  }

  /// The chosen bot, or nil for every bot. A bot that's gone falls back to nil.
  public var scope: String?
  public var total: Int
  public var counts: [String: Int]
  public var waiting: [Waiting]
  public var groups: [Group]
  /// A list in scope is still on its first read.
  public var isLoading: Bool
  /// Shown when every bot is in scope and no group is left.
  public var note: String?
}

extension BotSecret {
  func matches(_ needle: String) -> Bool {
    Self.matches(name: name, hosts: hosts, needle: needle)
  }

  fileprivate static func matches(name: String, hosts: [String], needle: String) -> Bool {
    needle.isEmpty || name.lowercased().contains(needle) || hosts.contains { $0.contains(needle) }
  }
}

extension BotSecretBoard {
  public func page(_ kind: BotSecretKind, bots: [Agent], scope: String?, search: String) -> BotSecretPage {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let scope = bots.contains { $0.id == scope } ? scope : nil
    let inScope = bots.filter { scope == nil || $0.id == scope }
    let waiting = inScope.flatMap { bot in
      requests(kind, agentID: bot.id)
        .filter { BotSecret.matches(name: $0.name, hosts: $0.hosts, needle: needle) }
        .map { BotSecretPage.Waiting(bot: bot, request: $0) }
    }
    let groups = inScope.compactMap { bot -> BotSecretPage.Group? in
      let all = items(kind, agentID: bot.id)
      let matching = all.filter { $0.matches(needle) }
      let error = readError(kind, agentID: bot.id)
      if scope == nil, error == nil, matching.isEmpty { return nil }
      let note = isLoaded(kind, agentID: bot.id) && matching.isEmpty
        ? (all.isEmpty ? kind.emptyText : kind.noMatchText) : nil
      return BotSecretPage.Group(bot: bot, items: matching, note: error == nil ? note : nil, error: error)
    }
    let counts = Dictionary(uniqueKeysWithValues: bots.map {
      ($0.id, items(kind, agentID: $0.id).count + requests(kind, agentID: $0.id).count)
    })
    let total = counts.values.reduce(0, +)
    let isLoading = inScope.contains { !isLoaded(kind, agentID: $0.id) && readError(kind, agentID: $0.id) == nil }
    let isEmpty = waiting.isEmpty && groups.isEmpty && !isLoading
    return BotSecretPage(
      scope: scope, total: total, counts: counts, waiting: waiting, groups: groups, isLoading: isLoading,
      note: isEmpty ? (total == 0 ? kind.emptyText : kind.noMatchText) : nil)
  }
}
