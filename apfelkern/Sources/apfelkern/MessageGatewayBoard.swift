import Foundation
import Observation

/// The server's message gateways and the sheet that edits one. A save applies at once and gives the
/// sheet back on failure. The list polls while it's open, since a gateway's connection advances on
/// the server. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class MessageGatewayBoard {
  private var loaded: [MessageGateway] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var order = ReadOrder()
  /// The settings to show for a gateway until the server answers, so a read can't take them away.
  private var saving: [String: GatewayConfig] = [:]

  public var draft: GatewayDraft?
  /// Failed saves waiting for the open sheet to close.
  private var returned: [(draft: GatewayDraft, error: String)] = []
  public private(set) var saveError = ""
  private var scope = 0
  private let pollInterval: Duration

  public init(pollInterval: Duration = .seconds(5)) {
    self.pollInterval = pollInterval
  }

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    readError = nil
    order = ReadOrder()
    saving = [:]
    returned = []
    closeDraft()
  }

  public var gateways: [MessageGateway] {
    loaded.map { gateway in
      var shown = gateway
      if let config = saving[gateway.id] { shown.config = config }
      return shown
    }
  }

  public func gateway(_ id: String) -> MessageGateway? { gateways.first { $0.id == id } }

  public func isUnconfirmed(_ gateway: MessageGateway) -> Bool { saving[gateway.id] != nil }

  /// Restarts the watch on a new connection.
  public var watchKey: Int { scope }

  /// Runs until cancelled, or until the connection changes.
  public func watch(client: APIClient) async {
    let version = scope
    while !Task.isCancelled {
      try? await Task.sleep(for: pollInterval)
      guard !Task.isCancelled, scope == version else { return }
      refresh(client: client)
    }
  }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      do {
        let gateways = try await client.messageGateways()
        guard scope == version, order.accept(read) else { return }
        loaded = gateways
        isLoaded = true
        readError = nil
      } catch {
        guard scope == version, order.accept(read) else { return }
        readError = friendlyError(error)
      }
    }
  }

  /// Never replaces an open sheet: it may hold edits, or a save that came back.
  public func edit(_ gateway: MessageGateway) {
    guard draft == nil, !isUnconfirmed(gateway) else { return }
    draft = GatewayDraft(gateway: gateway)
  }

  public func closeDraft() {
    draft = nil
    saveError = ""
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  public var canSave: Bool {
    guard let draft else { return false }
    return draft.isDirty && saving[draft.gatewayID] == nil
  }

  public func saveDraft(bots: [Agent], client: APIClient) {
    guard canSave, var draft else { return }
    draft.attempted = true
    self.draft = draft
    guard draft.errors(bots: bots).isEmpty else { return }
    let version = scope
    let id = draft.gatewayID
    saveError = ""
    saving[id] = draft.config
    closeDraft()
    Task {
      do {
        let saved = try await client.updateMessageGateway(id: id, config: draft.config)
        guard scope == version else { return }
        order.settle()
        if let index = loaded.firstIndex(where: { $0.id == saved.id }) { loaded[index] = saved }
      } catch {
        guard scope == version else { return }
        order.settle()
        giveBack(draft, error: friendlyError(error))
      }
      saving[id] = nil
      refresh(client: client)
    }
  }

  private func giveBack(_ failed: GatewayDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }
}

/// The account's event relay. Its connection depends on the relay, so saving shows a pending state
/// and the status comes from the server. A failed save keeps what the owner typed, and an answer
/// never replaces a URL typed since. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class EventRelayBoard {
  public private(set) var relay: EventRelay?
  public private(set) var readError: String?
  private var order = ReadOrder()
  /// The URL field. Empty removes the relay.
  public var url = ""
  public private(set) var isSaving = false
  public private(set) var saveError: String?
  private var scope = 0
  private let pollInterval: Duration

  public init(pollInterval: Duration = .seconds(1)) {
    self.pollInterval = pollInterval
  }

  public func reset() {
    scope += 1
    relay = nil
    readError = nil
    order = ReadOrder()
    url = ""
    isSaving = false
    saveError = nil
  }

  private var nextURL: String? {
    url.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  public var canSave: Bool {
    guard let relay, !isSaving else { return false }
    return nextURL != relay.url
  }

  /// Polls only while connecting: the connection advances on the server. Nil stops the watch.
  public var watchKey: Int? { relay?.status == .connecting ? scope : nil }

  /// Runs until cancelled, or until the relay stops connecting.
  public func watch(client: APIClient) async {
    while !Task.isCancelled, let key = watchKey {
      try? await Task.sleep(for: pollInterval)
      guard !Task.isCancelled, key == watchKey else { return }
      refresh(client: client)
    }
  }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      do {
        let relay = try await client.eventRelay()
        guard scope == version, order.accept(read) else { return }
        show(relay, sent: nil)
        readError = nil
      } catch {
        guard scope == version, order.accept(read) else { return }
        readError = friendlyError(error)
      }
    }
  }

  public func save(client: APIClient) {
    guard canSave else { return }
    let version = scope
    let sent = url
    let next = nextURL
    isSaving = true
    saveError = nil
    Task {
      do {
        let saved = try await client.updateEventRelay(url: next)
        guard scope == version else { return }
        order.settle()
        show(saved, sent: sent)
      } catch {
        guard scope == version else { return }
        saveError = friendlyError(error)
      }
      isSaving = false
    }
  }

  /// The field follows the server unless the owner has typed something it hasn't seen.
  private func show(_ next: EventRelay, sent: String?) {
    if url == (relay?.url ?? "") || url == sent { url = next.url ?? "" }
    relay = next
  }
}
