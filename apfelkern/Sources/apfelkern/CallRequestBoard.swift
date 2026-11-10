import Foundation
import Observation

/// What the owner has started on a waiting call request.
public struct CallRequestDecision: Hashable, Sendable {
  /// A decision is on its way to the server.
  public var sending = false
  /// The server's reason for refusing, which the owner can read.
  public var error = ""

  public init() {}
}

/// The selected bot's call requests and the owner's decisions on them. A request only reads as
/// decided once the server said so. Results that return after the selection or connection changed
/// are dropped.
@MainActor @Observable
public final class CallRequestBoard {
  /// The bot's requests as the server last listed them, newest first.
  public private(set) var requests: [CallRequest] = []
  public private(set) var decisions: [String: CallRequestDecision] = [:]
  /// Requests the chat shows, as their tool results saved them.
  private var shown: [String: CallRequest] = [:]
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
    requests = []
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
  public func current(_ request: CallRequest) -> CallRequest {
    requests.first { $0.id == request.id } ?? request
  }

  public func decision(for id: String) -> CallRequestDecision {
    decisions[id] ?? CallRequestDecision()
  }

  // MARK: Reading

  /// A new request in the messages is the cue to ask the server about it.
  public func refreshIfChanged(messages: [Message], client: APIClient) {
    let added = messages.compactMap(CallRequest.init(message:)).filter { shown[$0.id] == nil }
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
      let loaded = try? await client.callRequests(agentID)
      guard scope == version, read > settledReads, let loaded else { return }
      settledReads = read
      requests = loaded
    }
  }

  /// A request waits for the owner or a call is going on, and nothing in the chat says when that changes.
  public var needsPolling: Bool {
    requests.contains { $0.status == .pending || $0.status == .calling }
      || shown.values.contains { current($0).status == .pending || current($0).status == .calling }
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

  /// Places the call. A refusal leaves the request waiting, with the server's text in `decision(for:).error`.
  public func approve(_ request: CallRequest, client: APIClient) {
    decide(request.id, client: client) {
      try await $0.approveCallRequest(request.agentID, id: request.id)
    }
  }

  public func decline(_ request: CallRequest, client: APIClient) {
    decide(request.id, client: client) {
      try await $0.declineCallRequest(request.agentID, id: request.id)
    }
  }

  private func decide(
    _ id: String, client: APIClient,
    _ work: @escaping @MainActor (APIClient) async throws -> CallRequest
  ) {
    guard !decision(for: id).sending else { return }
    let version = scope
    decisions[id, default: CallRequestDecision()].sending = true
    decisions[id]?.error = ""
    Task {
      do {
        let decided = try await work(client)
        guard scope == version else { return }
        settledReads = reads
        if let index = requests.firstIndex(where: { $0.id == id }) {
          requests[index] = decided
        } else {
          requests.insert(decided, at: 0)
        }
        decisions[id] = nil
      } catch {
        guard scope == version else { return }
        settledReads = reads
        decisions[id]?.sending = false
        decisions[id]?.error = friendlyError(error)
      }
      refresh(client: client)
    }
  }
}
