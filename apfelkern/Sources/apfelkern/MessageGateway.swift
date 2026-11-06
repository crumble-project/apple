import Foundation

public struct GatewayAlias: Hashable, Sendable {
  public var handle: String
  public var botID: String

  public init(handle: String, botID: String) {
    self.handle = handle
    self.botID = botID
  }
}

public struct GatewayConfig: Hashable, Sendable {
  public var enabled = false
  public var defaultBotID: String?
  public var ownerID: String?
  public var allowedChannelIDs: [String] = []
  public var allowDirectMessages = false
  public var aliases: [GatewayAlias] = []

  public init(
    enabled: Bool = false, defaultBotID: String? = nil, ownerID: String? = nil, allowedChannelIDs: [String] = [],
    allowDirectMessages: Bool = false, aliases: [GatewayAlias] = []
  ) {
    self.enabled = enabled
    self.defaultBotID = defaultBotID
    self.ownerID = ownerID
    self.allowedChannelIDs = allowedChannelIDs
    self.allowDirectMessages = allowDirectMessages
    self.aliases = aliases
  }
}

public struct MessageGateway: Identifiable, Hashable, Sendable {
  public var id: String
  public var label: String
  /// The plugin setting that holds its token.
  public var secretKey: String
  public var tokenConfigured: Bool
  public var config: GatewayConfig
  public var status: ServiceConnection
  public var error: String?
  public var pendingCount: Int
  public var failedCount: Int

  public init(
    id: String, label: String, secretKey: String, tokenConfigured: Bool, config: GatewayConfig,
    status: ServiceConnection, error: String? = nil, pendingCount: Int = 0, failedCount: Int = 0
  ) {
    self.id = id
    self.label = label
    self.secretKey = secretKey
    self.tokenConfigured = tokenConfigured
    self.config = config
    self.status = status
    self.error = error
    self.pendingCount = pendingCount
    self.failedCount = failedCount
  }

  public var statusLabel: String {
    guard config.enabled else { return "Disabled" }
    return switch status {
    case .disconnected: "Disconnected"
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .error: "Connection error"
    }
  }

  public var isFailing: Bool { config.enabled && status == .error }

  /// Messages waiting to go out or that couldn't, if any.
  public var deliveries: String {
    [pendingCount > 0 ? "\(pendingCount) pending" : "", failedCount > 0 ? "\(failedCount) failed" : ""]
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  /// The bots a picker offers, with a saved bot that no longer exists so it still shows.
  public static func botChoices(_ bots: [Agent], keeping saved: String?) -> [GatewayBotChoice] {
    var choices = bots.map { GatewayBotChoice(id: $0.id, name: $0.enabled ? $0.name : "\($0.name) (disabled)") }
    if let saved, !saved.isEmpty, !bots.contains(where: { $0.id == saved }) {
      choices.append(GatewayBotChoice(id: saved, name: "Deleted bot"))
    }
    return choices
  }
}

public struct GatewayBotChoice: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
}

/// What's wrong with a gateway draft, by the part of the form that shows it.
public struct GatewayDraftErrors: Equatable, Sendable {
  public var defaultBot: String?
  public var owner: String?
  public var aliases: String?
  public var channels: String?

  var isEmpty: Bool { self == GatewayDraftErrors() }
}

/// The editor for a gateway's settings. Rows have their own IDs so they survive edits and blanks.
public struct GatewayDraft: Identifiable, Sendable {
  public struct AliasRow: Identifiable, Sendable {
    public let id = UUID()
    public var handle = ""
    public var botID = ""

    public init() {}

    init(handle: String, botID: String) {
      self.handle = handle
      self.botID = botID
    }
  }

  public struct ChannelRow: Identifiable, Sendable {
    public let id = UUID()
    public var value = ""

    public init() {}

    init(value: String) { self.value = value }
  }

  /// The most characters the server takes for a user or channel ID, and for an alias.
  public static let maxIDLength = 200
  public static let maxAliasLength = 100
  private static let maxRows = 1000

  public let id = UUID()
  public let gatewayID: String
  public let label: String
  let saved: GatewayConfig
  public var enabled = false
  public var defaultBotID: String?
  public var ownerID = ""
  public var allowDirectMessages = false
  public var channels: [ChannelRow] = []
  public var aliases: [AliasRow] = []
  var attempted = false

  public init(gateway: MessageGateway) {
    gatewayID = gateway.id
    label = gateway.label
    saved = gateway.config
    reset()
  }

  public var isDirty: Bool { config != saved }

  /// Back to the saved settings. Keeps `id`, so the open sheet stays open.
  public mutating func reset() {
    enabled = saved.enabled
    defaultBotID = saved.defaultBotID
    ownerID = saved.ownerID ?? ""
    allowDirectMessages = saved.allowDirectMessages
    channels = saved.allowedChannelIDs.map { ChannelRow(value: $0) }
    aliases = saved.aliases.map { AliasRow(handle: $0.handle, botID: $0.botID) }
    attempted = false
  }

  public var ownerLabel: String { "Owner \(label) user ID" }

  /// What a save sends: trimmed, with blank and repeated channels dropped.
  public var config: GatewayConfig {
    var seen: Set<String> = []
    return GatewayConfig(
      enabled: enabled,
      defaultBotID: defaultBotID,
      ownerID: ownerID.trimmed.nilIfEmpty,
      allowedChannelIDs: channels.map(\.value.trimmed).filter { !$0.isEmpty && seen.insert($0).inserted },
      allowDirectMessages: allowDirectMessages,
      aliases: aliases.map { GatewayAlias(handle: $0.handle.trimmed, botID: $0.botID) })
  }

  /// What the form shows: nothing until Save was pressed.
  public func shownErrors(bots: [Agent]) -> GatewayDraftErrors {
    attempted ? errors(bots: bots) : GatewayDraftErrors()
  }

  /// The server's rules, plus bots that were deleted, which only block a gateway that's on.
  func errors(bots: [Agent]) -> GatewayDraftErrors {
    let config = config
    var errors = GatewayDraftErrors()
    if let owner = config.ownerID, owner.utf16.count > Self.maxIDLength || owner.wholeMatch(of: /[^\s,]+/) == nil {
      errors.owner = "Enter one user ID, without spaces or commas."
    }
    if config.allowedChannelIDs.count > Self.maxRows
      || config.allowedChannelIDs.contains(where: { $0.utf16.count > Self.maxIDLength }) {
      errors.channels = "Use at most \(Self.maxRows) channels of \(Self.maxIDLength) characters each."
    }
    errors.aliases = aliasError(config.aliases)
    let exists = { (id: String?) in bots.contains { $0.id == id } }
    if config.enabled, let bot = config.defaultBotID, !exists(bot) {
      errors.defaultBot = "The saved bot was deleted. Choose another."
    }
    if config.enabled, config.aliases.contains(where: { !$0.botID.isEmpty && !exists($0.botID) }) {
      errors.aliases = "Choose an existing bot for every alias."
    }
    return errors
  }

  private func aliasError(_ aliases: [GatewayAlias]) -> String? {
    let handleIsValid = { (handle: String) in
      handle.utf16.count <= Self.maxAliasLength && handle.wholeMatch(of: /[\p{L}\p{N}_-]+/) != nil
    }
    if aliases.count > Self.maxRows { return "Use at most \(Self.maxRows) aliases." }
    if aliases.contains(where: { !handleIsValid($0.handle) }) {
      return "Use letters, numbers, underscores or hyphens, without @."
    }
    if aliases.contains(where: { $0.botID.isEmpty }) { return "Choose a bot for every alias." }
    let handles = aliases.map { $0.handle.precomposedStringWithCompatibilityMapping.lowercased() }
    return Set(handles).count == handles.count ? nil : "Alias handles must be unique (ignoring case)."
  }
}

private extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
