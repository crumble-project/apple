import Foundation

extension PasswordManager {
  init?(wire: Components.Schemas.PasswordManager) {
    guard let id = PasswordManagerID(rawValue: wire.id.rawValue) else { return nil }
    self.init(id: id, name: wire.name, connected: wire.connected, usedBy: wire.usedBy)
  }
}

extension PluginSetting {
  init(wire: Components.Schemas.PluginSetting, pluginID: String, contributes: Set<PluginContribution>) {
    self.init(
      pluginID: pluginID, key: wire.key, label: wire.label, contributes: contributes,
      secret: SecretStatus(wire: wire.secret))
  }
}

private typealias GatewayWire = Operations.MessageGateways.Output.Ok.Body.JsonPayload.GatewaysPayloadPayload
private typealias RelayWire = Operations.GetEventRelay.Output.Ok.Body.JsonPayload

extension APIClient {
  public func passwordManagers() async throws -> [PasswordManager] {
    try await invoke {
      try await $0.listPasswordManagers(.init()).ok.body.json.passwordManagers.compactMap(PasswordManager.init(wire:))
    }
  }

  /// The server signs in with the token before it answers, so this can take a while.
  func connectPasswordManager(_ id: PasswordManagerID, token: String) async throws -> PasswordManager {
    guard let path = Operations.ConnectPasswordManager.Input.Path.IdPayload(rawValue: id.rawValue) else {
      throw URLError(.badURL)
    }
    return try await invoke(timeout: 60) {
      let wire = try await $0.connectPasswordManager(
        .init(path: .init(id: path), body: .json(.init(token: token)))).ok.body.json
      return try required(PasswordManager(wire: wire))
    }
  }

  /// 409 while a secret still reads from it.
  public func disconnectPasswordManager(_ id: PasswordManagerID) async throws {
    guard let path = Operations.DisconnectPasswordManager.Input.Path.IdPayload(rawValue: id.rawValue) else {
      throw URLError(.badURL)
    }
    try await invoke { _ = try await $0.disconnectPasswordManager(.init(path: .init(id: path))).noContent }
  }

  public func pluginSettings() async throws -> [PluginSetting] {
    try await invoke {
      try await $0.listPluginSettings(.init()).ok.body.json.plugins.flatMap { plugin in
        let contributes = Set(plugin.contributes.compactMap { PluginContribution(rawValue: $0.rawValue) })
        return plugin.settings.map { PluginSetting(wire: $0, pluginID: plugin.id, contributes: contributes) }
      }
    }
  }

  /// A reference is read once to check it before the server answers.
  func setPluginSetting(_ setting: PluginSetting, to input: SecretInput) async throws -> PluginSetting {
    let body: Operations.SetPluginSetting.Input.Body.JsonPayload = try requestModel(SecretBody(input))
    return try await invoke(timeout: 60) {
      PluginSetting(
        wire: try await $0.setPluginSetting(
          .init(path: .init(pluginId: setting.pluginID, key: setting.key), body: .json(body))).ok.body.json,
        pluginID: setting.pluginID, contributes: setting.contributes)
    }
  }

  public func deletePluginSetting(_ setting: PluginSetting) async throws -> PluginSetting {
    try await invoke {
      PluginSetting(
        wire: try await $0.deletePluginSetting(
          .init(path: .init(pluginId: setting.pluginID, key: setting.key))).ok.body.json,
        pluginID: setting.pluginID, contributes: setting.contributes)
    }
  }

  public func messageGateways() async throws -> [MessageGateway] {
    try await invoke { try await $0.messageGateways(.init()).ok.body.json.gateways.map(gateway) }
  }

  /// The server reconnects the gateway before it answers.
  public func updateMessageGateway(id: String, config: GatewayConfig) async throws -> MessageGateway {
    var cleared: Set<String> = []
    if config.defaultBotID == nil { cleared.insert("defaultBotId") }
    if config.ownerID == nil { cleared.insert("ownerId") }
    return try await invoke(timeout: 60, nullFields: cleared) {
      let wire = try await $0.updateMessageGateway(.init(
        path: .init(id: id),
        body: .json(.init(
          aliases: config.aliases.map { .init(botId: $0.botID, handle: $0.handle) },
          allowDirectMessages: config.allowDirectMessages, allowedChannelIds: config.allowedChannelIDs,
          defaultBotId: config.defaultBotID, enabled: config.enabled, ownerId: config.ownerID)))).ok.body.json
      return try gateway(try requestModel(wire))
    }
  }

  public func eventRelay() async throws -> EventRelay {
    try await invoke { try relay(try await $0.getEventRelay(.init()).ok.body.json) }
  }

  /// A nil URL removes the relay and disconnects it. The server reconnects before it answers.
  public func updateEventRelay(url: String?) async throws -> EventRelay {
    try await invoke(timeout: 60, nullFields: url == nil ? ["url"] : []) {
      let wire = try await $0.updateEventRelay(.init(body: .json(.init(url: url)))).ok.body.json
      return try relay(try requestModel(wire))
    }
  }

  public func eventSources() async throws -> [EventSource] {
    try await invoke {
      try await $0.listEventSources(.init()).ok.body.json.sources.map {
        EventSource(id: $0.id, name: $0.name, usedBy: $0.usedBy)
      }
    }
  }

  /// The server creates the source on the relay before it answers. The address comes only here.
  public func createEventSource(name: String) async throws -> CreatedEventSource {
    try await invoke(timeout: 60) {
      let wire = try await $0.createEventSource(.init(body: .json(.init(name: name)))).created.body.json
      return CreatedEventSource(
        source: EventSource(id: wire.id, name: wire.name, usedBy: wire.usedBy), address: wire.address)
    }
  }

  /// The server deletes the source on the relay before it answers. 409 while an automation uses it.
  public func deleteEventSource(_ id: String) async throws {
    try await invoke(timeout: 60) { _ = try await $0.deleteEventSource(.init(path: .init(id: id))).noContent }
  }

  private func gateway(_ wire: GatewayWire) throws -> MessageGateway {
    MessageGateway(
      id: wire.id, label: wire.label, secretKey: wire.secretKey, tokenConfigured: wire.tokenConfigured,
      config: GatewayConfig(
        enabled: wire.config.enabled, defaultBotID: wire.config.defaultBotId, ownerID: wire.config.ownerId,
        allowedChannelIDs: wire.config.allowedChannelIds, allowDirectMessages: wire.config.allowDirectMessages,
        aliases: wire.config.aliases.map { GatewayAlias(handle: $0.handle, botID: $0.botId) }),
      status: try required(ServiceConnection(rawValue: wire.status.rawValue)), error: wire.error,
      pendingCount: wire.pendingCount, failedCount: wire.failedCount)
  }

  private func relay(_ wire: RelayWire) throws -> EventRelay {
    EventRelay(
      url: wire.url, tokenConfigured: wire.tokenConfigured,
      status: try required(ServiceConnection(rawValue: wire.status.rawValue)), error: wire.error)
  }
}
