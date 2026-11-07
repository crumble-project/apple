import Foundation

extension APIClient {
  /// Newest first. `before` is the last change of the previous page; `agentID` narrows to one bot.
  public func changes(agentID: String? = nil, before: String? = nil, limit: Int) async throws -> [LearnedChange] {
    try await invoke {
      try await $0.listChanges(.init(query: .init(
        limit: limit, before: before, agentId: agentID.map { .init(value1: $0) }))).ok.body.json
        .map(LearnedChange.init(wire:))
    }
  }

  /// Returns the revert, which the server records as a change of its own.
  public func revertChange(_ id: String) async throws -> LearnedChange {
    try await invoke {
      try LearnedChange(wire: try await $0.revertChange(.init(path: .init(id: id))).created.body.json)
    }
  }
}
