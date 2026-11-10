import Foundation

extension PasswordManager {
  init?(wire: Components.Schemas.PasswordManager) {
    guard let id = PasswordManagerID(rawValue: wire.id.rawValue) else { return nil }
    self.init(id: id, name: wire.name, connected: wire.connected)
  }
}

extension APIClient {
  public func passwordManagers() async throws -> [PasswordManager] {
    try await invoke {
      try await $0.listPasswordManagers(.init()).ok.body.json.passwordManagers.compactMap(PasswordManager.init(wire:))
    }
  }

  public func eventSources() async throws -> [EventSource] {
    try await invoke {
      try await $0.listEventSources(.init()).ok.body.json.sources.map { EventSource(id: $0.id, name: $0.name) }
    }
  }
}
