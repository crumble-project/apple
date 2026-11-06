import Foundation
import Observation

public struct BotSecretTarget: Hashable, Sendable {
  public var kind: BotSecretKind
  public var agentID: String
  public var name: String

  public init(kind: BotSecretKind, agentID: String, name: String) {
    self.kind = kind
    self.agentID = agentID
    self.name = name
  }
}

/// What a request's card in the chat shows.
public enum BotSecretAskState: Hashable, Sendable {
  case waiting(BotSecretRequest)
  case outcome(String)
}

/// The uses of one credential or login, a page at a time.
@MainActor @Observable
public final class BotSecretUseLog: Identifiable {
  public let target: BotSecretTarget
  public private(set) var uses: [BotSecretUse] = []
  public private(set) var loading = false
  public private(set) var error = ""
  public private(set) var hasMore = true
  private let pageSize: Int

  init(target: BotSecretTarget, pageSize: Int = 50) {
    self.target = target
    self.pageSize = pageSize
  }

  public func loadMore(client: APIClient) {
    guard !loading, hasMore else { return }
    loading = true
    error = ""
    let before = uses.last?.id ?? ""
    Task {
      defer { loading = false }
      do {
        let page = try await client.botSecretUses(
          target.kind, agentID: target.agentID, name: target.name, before: before, limit: pageSize)
        uses += page
        hasMore = page.count == pageSize
      } catch {
        self.error = friendlyError(error)
      }
    }
  }
}

/// Each bot's credentials and logins, the sheet that edits one, and the requests the selected bot's
/// chat shows. Saves and deletes apply at once; a failed save gives the sheet back with what the
/// owner typed. A password manager check holds the sheet until the server answers, and declining
/// shows a pending state. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class BotSecretBoard {
  private struct ListKey: Hashable {
    var agentID: String
    var kind: BotSecretKind
  }

  private var lists: [ListKey: BotSecretList] = [:]
  private var readErrors: [ListKey: String] = [:]
  private var reads: [ListKey: Int] = [:]
  /// Reads up to this one are ignored: they may predate a newer read or a write.
  private var settledReads: [ListKey: Int] = [:]
  /// Hidden from the list until the server answers, so a read can't bring them back.
  private var removing: Set<BotSecretTarget> = []
  /// Shown in the list until the server answers, so a read can't take them away.
  private var saving: [BotSecretTarget: BotSecret] = [:]
  public private(set) var declining: Set<BotSecretTarget> = []
  /// Why deleting or declining failed.
  public private(set) var errors: [BotSecretTarget: String] = [:]

  /// The open sheet. Only here, in a save in flight, and in `returned` do typed values live.
  public var draft: BotSecretDraft?
  /// Failed saves waiting for the open sheet to close.
  private var returned: [(draft: BotSecretDraft, error: String)] = []
  /// The open sheet's draft is with a password manager check. The server may already have stored it,
  /// so the sheet can't close until it answers.
  public private(set) var isSaving = false
  public private(set) var saveError = ""
  public private(set) var connectedManagers: [PasswordManager] = []
  public var useLog: BotSecretUseLog?

  private var agentID = ""
  /// Requests with a card in the selected bot's chat.
  private var shown: Set<BotSecretAsk> = []
  /// Shown requests a read has answered for since they appeared; until then the list can predate them.
  private var answered: Set<BotSecretAsk> = []
  private var scope = 0
  private let pollInterval: Duration

  public init(pollInterval: Duration = .seconds(5)) {
    self.pollInterval = pollInterval
  }

  public func reset() {
    scope += 1
    agentID = ""
    lists = [:]
    readErrors = [:]
    reads = [:]
    settledReads = [:]
    removing = []
    declining = []
    errors = [:]
    saving = [:]
    returned = []
    isSaving = false
    closeDraft()
    connectedManagers = []
    useLog = nil
    shown = []
    answered = []
  }

  /// Reopening a chat reads its requests anew; one may have ended since.
  public func select(_ agentID: String) {
    self.agentID = agentID
    shown = []
    answered = []
  }

  // MARK: Reading

  public func isLoaded(_ kind: BotSecretKind, agentID: String) -> Bool {
    lists[ListKey(agentID: agentID, kind: kind)] != nil
  }

  public func readError(_ kind: BotSecretKind, agentID: String) -> String? {
    readErrors[ListKey(agentID: agentID, kind: kind)]
  }

  public func items(_ kind: BotSecretKind, agentID: String) -> [BotSecret] {
    var items = lists[ListKey(agentID: agentID, kind: kind)]?.items ?? []
    items.removeAll { removing.contains(BotSecretTarget(kind: kind, agentID: agentID, name: $0.name)) }
    let unconfirmed = saving.filter { $0.key.kind == kind && $0.key.agentID == agentID }.values
    for item in unconfirmed.sorted(by: { $0.name < $1.name }) { put(item, in: &items) }
    return items
  }

  public func requests(_ kind: BotSecretKind, agentID: String) -> [BotSecretRequest] {
    let requests = lists[ListKey(agentID: agentID, kind: kind)]?.requests ?? []
    return requests.filter { !isUnconfirmed(BotSecretTarget(kind: kind, agentID: agentID, name: $0.name)) }
  }

  /// Its row shows what the owner saved, and the server hasn't answered yet.
  public func isUnconfirmed(_ target: BotSecretTarget) -> Bool { saving[target] != nil }

  public func refresh(_ kind: BotSecretKind, agentID: String, client: APIClient) {
    let key = ListKey(agentID: agentID, kind: kind)
    let version = scope
    let asked = agentID == self.agentID ? shown.filter { $0.kind == kind } : []
    let read = reads[key, default: 0] + 1
    reads[key] = read
    Task {
      do {
        let loaded = try await client.botSecrets(kind, agentID: agentID)
        guard scope == version, read > settledReads[key, default: 0] else { return }
        settledReads[key] = read
        lists[key] = loaded
        readErrors[key] = nil
        answered.formUnion(asked)
      } catch {
        guard scope == version, read > settledReads[key, default: 0] else { return }
        readErrors[key] = friendlyError(error)
      }
    }
  }

  public func refresh(agentID: String, client: APIClient) {
    for kind in BotSecretKind.allCases { refresh(kind, agentID: agentID, client: client) }
  }

  // MARK: Requests in the chat

  /// A new request in the messages is the cue to ask the server about it.
  public func refreshIfChanged(messages: [Message], client: APIClient) {
    let asks = Set(messages.compactMap(BotSecretAsk.init(message:)))
    let added = asks.subtracting(shown)
    guard !added.isEmpty, !agentID.isEmpty else { return }
    shown.formUnion(added)
    for kind in Set(added.map(\.kind)) { refresh(kind, agentID: agentID, client: client) }
  }

  public func state(of ask: BotSecretAsk) -> BotSecretAskState {
    if let waiting = waiting(ask) { return .waiting(waiting) }
    guard answered.contains(ask) else {
      return .outcome(readError(ask.kind, agentID: agentID) == nil ? "Loading…" : "Unavailable")
    }
    let saved = items(ask.kind, agentID: agentID).contains { $0.name == ask.name }
    return .outcome(saved ? "Saved" : "Declined")
  }

  private func waiting(_ ask: BotSecretAsk) -> BotSecretRequest? {
    requests(ask.kind, agentID: agentID).first(where: ask.matches)
  }

  /// Another client can settle a request, and nothing in the chat says so.
  public var needsPolling: Bool {
    shown.contains { !answered.contains($0) || waiting($0) != nil }
  }

  /// Runs until cancelled.
  public func watch(client: APIClient) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: pollInterval)
      guard !Task.isCancelled else { return }
      for kind in Set(shown.map(\.kind)) { refresh(kind, agentID: agentID, client: client) }
    }
  }

  // MARK: Saving

  public func startNew(_ kind: BotSecretKind, agentID: String, client: APIClient) {
    open(BotSecretDraft(kind: kind, agentID: agentID), client: client)
  }

  /// From a page across every bot: the sheet asks which bot it's for.
  public func startNew(_ kind: BotSecretKind, choosingFrom bots: [Agent], client: APIClient) {
    guard let first = bots.first else { return }
    open(BotSecretDraft(kind: kind, agentID: first.id, choosesBot: true), client: client)
  }

  public func edit(_ item: BotSecret, agentID: String, client: APIClient) {
    let target = BotSecretTarget(kind: item.kind, agentID: agentID, name: item.name)
    guard !item.managed, !isUnconfirmed(target) else { return }
    open(BotSecretDraft(kind: item.kind, agentID: agentID, existing: item), client: client)
  }

  /// `agentID` is the bot that asked.
  public func add(_ request: BotSecretRequest, kind: BotSecretKind, agentID: String, client: APIClient) {
    open(BotSecretDraft(kind: kind, agentID: agentID, request: request), client: client)
  }

  /// Never replaces an open sheet: it may hold what the owner typed, or a save that came back.
  private func open(_ next: BotSecretDraft, client: APIClient) {
    guard draft == nil else { return }
    draft = next
    let version = scope
    Task {
      guard let managers = try? await client.passwordManagers(), scope == version else { return }
      connectedManagers = managers.filter(\.connected)
    }
  }

  public var canSave: Bool {
    guard let draft, draft.isReady, !isSaving else { return false }
    return !isUnconfirmed(BotSecretTarget(kind: draft.kind, agentID: draft.agentID, name: draft.name))
  }

  public func closeDraft() {
    guard !isSaving else { return }
    draft?.clearSecrets()
    draft = nil
    saveError = ""
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  public func saveDraft(client: APIClient) {
    guard canSave, let draft else { return }
    saveError = ""
    if draft.checksPasswordManager {
      saveAfterCheck(draft, client: client)
    } else {
      saveAtOnce(draft, client: client)
    }
  }

  private func saveAfterCheck(_ draft: BotSecretDraft, client: APIClient) {
    let key = ListKey(agentID: draft.agentID, kind: draft.kind)
    let version = scope
    isSaving = true
    Task {
      do {
        let saved = try await client.saveBotSecret(draft)
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        store(saved, in: key)
        isSaving = false
        closeDraft()
        refresh(draft.kind, agentID: draft.agentID, client: client)
      } catch {
        guard scope == version else { return }
        isSaving = false
        saveError = friendlyError(error)
      }
    }
  }

  private func saveAtOnce(_ draft: BotSecretDraft, client: APIClient) {
    let key = ListKey(agentID: draft.agentID, kind: draft.kind)
    let target = BotSecretTarget(kind: draft.kind, agentID: draft.agentID, name: draft.name)
    let version = scope
    saving[target] = draft.provisional
    closeDraft()
    Task {
      do {
        let saved = try await client.saveBotSecret(draft)
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        store(saved, in: key)
      } catch {
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        giveBack(draft, error: friendlyError(error))
      }
      saving[target] = nil
      refresh(draft.kind, agentID: draft.agentID, client: client)
    }
  }

  private func giveBack(_ failed: BotSecretDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }

  private func store(_ saved: BotSecret, in key: ListKey) {
    var list = lists[key] ?? BotSecretList()
    list.requests.removeAll { $0.name == saved.name }
    put(saved, in: &list.items)
    lists[key] = list
  }

  private func put(_ item: BotSecret, in items: inout [BotSecret]) {
    if let index = items.firstIndex(where: { $0.name == item.name }) {
      items[index] = item
    } else {
      items.append(item)
    }
  }

  // MARK: Removing

  public func delete(_ item: BotSecret, agentID: String, client: APIClient) {
    let key = ListKey(agentID: agentID, kind: item.kind)
    let target = BotSecretTarget(kind: item.kind, agentID: agentID, name: item.name)
    guard !item.managed, !isUnconfirmed(target), removing.insert(target).inserted else { return }
    errors[target] = nil
    let version = scope
    Task {
      do {
        try await client.deleteBotSecret(item.kind, agentID: agentID, name: item.name)
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        lists[key]?.items.removeAll { $0.name == item.name }
      } catch {
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        errors[target] = friendlyError(error)
      }
      removing.remove(target)
      refresh(item.kind, agentID: agentID, client: client)
    }
  }

  /// A request only leaves once the server said so; a refusal keeps it with the error.
  public func decline(_ request: BotSecretRequest, kind: BotSecretKind, agentID: String, client: APIClient) {
    let key = ListKey(agentID: agentID, kind: kind)
    let target = BotSecretTarget(kind: kind, agentID: agentID, name: request.name)
    guard declining.insert(target).inserted else { return }
    errors[target] = nil
    let version = scope
    Task {
      do {
        try await client.declineBotSecret(kind, agentID: agentID, name: request.name)
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        lists[key]?.requests.removeAll { $0.name == request.name }
      } catch {
        guard scope == version else { return }
        settledReads[key] = reads[key, default: 0]
        errors[target] = friendlyError(error)
      }
      declining.remove(target)
      refresh(kind, agentID: agentID, client: client)
    }
  }

  // MARK: Uses

  public func showUses(of item: BotSecret, agentID: String, client: APIClient) {
    let log = BotSecretUseLog(target: BotSecretTarget(kind: item.kind, agentID: agentID, name: item.name))
    useLog = log
    log.loadMore(client: client)
  }
}
