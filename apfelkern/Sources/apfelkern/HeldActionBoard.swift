import Foundation
import Observation

/// What a held action's card shows: the owner's choice, or the one line left once it needs nothing.
public enum HeldActionState: Hashable, Sendable {
  case waiting(HeldAction)
  case outcome(String)
}

/// What the owner has started on a waiting action, kept across scrolling and failed sends.
public struct HeldActionDecision: Hashable, Sendable {
  public var declining = false
  public var reason = ""
  /// A decision is on its way to the server.
  public var sending = false
  public var error = ""

  public init() {}
}

/// The selected bot's held actions and the owner's decisions on them. An action only reads as
/// decided once the server said so. Results that return after the selection or connection changed
/// are dropped.
@MainActor @Observable
public final class HeldActionBoard {
  private var actions: [String: HeldAction] = [:]
  /// Keyed by action ID.
  public var decisions: [String: HeldActionDecision] = [:]
  /// Actions with a `held-action` event in the chat.
  private var shown: Set<String> = []
  /// Shown actions a read has answered for since they appeared; until then the list can predate them.
  private var answered: Set<String> = []
  private var readFailed = false
  private var reads = 0
  /// Reads up to this one are ignored: they may predate a newer read or a decision.
  private var settledReads = 0
  private var agentID = ""
  private var scope = 0
  private let pollInterval: Duration

  public init(pollInterval: Duration = .seconds(5)) {
    self.pollInterval = pollInterval
  }

  public func reset() {
    scope += 1
    agentID = ""
    actions = [:]
    decisions = [:]
    shown = []
    answered = []
    readFailed = false
  }

  /// Reopening the same bot's chat keeps unsent decisions; a waiting action may have ended since, so
  /// its card reads the list anew.
  public func select(_ agentID: String) {
    shown = []
    answered = []
    guard agentID != self.agentID else { return }
    reset()
    self.agentID = agentID
  }

  public func state(of id: String) -> HeldActionState {
    let action = actions[id]
    switch action?.status {
    case .approved: return .outcome("Approved")
    case .declined: return .outcome("Declined")
    case .expired: return .outcome("Expired")
    case .pending, nil: break
    }
    if answered.contains(id) { return action.map(HeldActionState.waiting) ?? .outcome("Unavailable") }
    return .outcome(readFailed ? "Unavailable" : "Loading…")
  }

  public func decision(for id: String) -> HeldActionDecision {
    decisions[id] ?? HeldActionDecision()
  }

  // MARK: Reading

  /// A held action arrives as an event, so a new one in the messages is the cue to ask the server.
  public func refreshIfChanged(messages: [Message], client: APIClient) {
    let events = Set(messages.compactMap(\.heldAction?.id))
    guard !events.isSubset(of: shown) else { return }
    shown.formUnion(events)
    refresh(client: client)
  }

  public func refresh(client: APIClient) {
    guard !agentID.isEmpty else { return }
    let version = scope
    let agentID = agentID
    let asked = shown
    reads += 1
    let read = reads
    Task {
      do {
        let loaded = try await client.heldActions(agentID)
        guard scope == version, read > settledReads else { return }
        settledReads = read
        actions = Dictionary(loaded.map { ($0.id, $0) }) { first, _ in first }
        answered.formUnion(asked)
        readFailed = false
      } catch {
        guard scope == version, read > settledReads else { return }
        readFailed = true
      }
    }
  }

  /// A stopped job, a restart, or another client can end a waiting action, and a read that failed
  /// leaves a card without an answer.
  public var needsPolling: Bool {
    shown.contains { actions[$0]?.status == .pending || !answered.contains($0) }
  }

  /// Runs until cancelled.
  public func watch(client: APIClient) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: pollInterval)
      guard !Task.isCancelled else { return }
      refresh(client: client)
    }
  }

  // MARK: Deciding

  public func approve(_ id: String, client: APIClient) {
    let agentID = agentID
    decide(id, client: client) { try await $0.approveHeldAction(agentID, id: id) }
  }

  public func decline(_ id: String, client: APIClient) {
    let agentID = agentID
    let reason = decision(for: id).reason.trimmingCharacters(in: .whitespacesAndNewlines)
    decide(id, client: client) { try await $0.declineHeldAction(agentID, id: id, reason: reason) }
  }

  /// The action's outcome belongs to the server, so the card shows a pending state. A refusal leaves
  /// it waiting with the error, and what the owner wrote in place for another try.
  private func decide(
    _ id: String, client: APIClient,
    _ work: @escaping @MainActor (APIClient) async throws -> HeldAction
  ) {
    guard !agentID.isEmpty, !decision(for: id).sending else { return }
    let version = scope
    decisions[id, default: HeldActionDecision()].sending = true
    decisions[id]?.error = ""
    Task {
      do {
        let decided = try await work(client)
        guard scope == version else { return }
        settledReads = reads
        actions[id] = decided
        decisions[id] = nil
      } catch {
        guard scope == version else { return }
        settledReads = reads
        decisions[id]?.sending = false
        decisions[id]?.error = friendlyError(error)
      }
      // A 409 means someone else decided it, or it expired; the list settles the card.
      refresh(client: client)
    }
  }
}
