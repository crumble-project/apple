import Foundation
import Observation

/// What the owner has started on a waiting request.
public struct BotRequestDecision: Hashable, Sendable {
  /// A decision is on its way to the server.
  public var sending = false
  public var error = ""

  public init() {}
}

/// The selected bot's bot requests and the owner's decisions on them. A request only reads as
/// decided once the server said so. Results that return after the selection or connection changed
/// are dropped; a bot an approval created is still reported.
@MainActor @Observable
public final class BotRequestBoard {
  private var requests: [String: BotRequest] = [:]
  public private(set) var decisions: [String: BotRequestDecision] = [:]
  /// Requests the chat shows, as their tool results saved them.
  private var shown: [String: BotRequest] = [:]
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
    requests = [:]
    decisions = [:]
    shown = [:]
  }

  /// Reopening the same bot's chat keeps its decisions; a request may have ended since, so the
  /// next messages read the list anew.
  public func select(_ agentID: String) {
    shown = [:]
    guard agentID != self.agentID else { return }
    reset()
    self.agentID = agentID
  }

  /// The request as the server last reported it, or as it was saved until the list has answered.
  public func current(_ request: BotRequest) -> BotRequest {
    requests[request.id] ?? request
  }

  public func decision(for id: String) -> BotRequestDecision {
    decisions[id] ?? BotRequestDecision()
  }

  // MARK: Reading

  /// A new request in the messages is the cue to ask the server about it.
  public func refreshIfChanged(messages: [Message], client: APIClient) {
    let added = messages.compactMap(BotRequest.init(message:)).filter { shown[$0.id] == nil }
    guard !added.isEmpty else { return }
    for request in added { shown[request.id] = request }
    refresh(client: client)
  }

  public func refresh(client: APIClient) {
    guard !agentID.isEmpty else { return }
    let version = scope
    let agentID = agentID
    reads += 1
    let read = reads
    Task {
      let loaded = try? await client.botRequests(agentID)
      guard scope == version, read > settledReads, let loaded else { return }
      settledReads = read
      requests = Dictionary(loaded.map { ($0.id, $0) }) { first, _ in first }
    }
  }

  /// Another client can decide a request, and nothing in the chat says so.
  public var needsPolling: Bool {
    shown.values.contains { current($0).status == .pending }
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

  /// Creates the bot as proposed, or as `bot` when the owner edited it. `onApproved` gets the new
  /// bot even if the owner has moved on, since the server created it either way.
  public func approve(
    _ request: BotRequest, editedTo bot: Agent? = nil, client: APIClient,
    onApproved: @escaping @MainActor (Agent) -> Void
  ) {
    decide(request.id, client: client) {
      let approval = try await $0.approveBotRequest(
        request.agentID, id: request.id, proposal: try bot.map { try request.proposal(editedTo: $0) })
      onApproved(approval.agent)
      return approval.request
    }
  }

  public func decline(_ request: BotRequest, client: APIClient) {
    decide(request.id, client: client) {
      try await $0.declineBotRequest(request.agentID, id: request.id)
    }
  }

  /// The outcome belongs to the server, so the card shows a pending state. A refusal leaves it
  /// waiting with the error.
  private func decide(
    _ id: String, client: APIClient,
    _ work: @escaping @MainActor (APIClient) async throws -> BotRequest
  ) {
    guard !decision(for: id).sending else { return }
    let version = scope
    decisions[id, default: BotRequestDecision()].sending = true
    decisions[id]?.error = ""
    Task {
      do {
        let decided = try await work(client)
        guard scope == version else { return }
        settledReads = reads
        requests[id] = decided
        decisions[id] = nil
      } catch {
        guard scope == version else { return }
        settledReads = reads
        decisions[id]?.sending = false
        decisions[id]?.error = friendlyError(error)
      }
      // A 409 means someone else decided it; the list settles the card.
      refresh(client: client)
    }
  }
}
