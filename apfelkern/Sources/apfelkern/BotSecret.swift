import Foundation

/// The two things an owner gives a bot: a credential for coding jobs, a login for desktop jobs.
public enum BotSecretKind: String, CaseIterable, Hashable, Sendable {
  case credential
  case login

  /// The bot's tool that asks the owner for one.
  public var toolName: String {
    switch self {
    case .credential: "request_credential"
    case .login: "request_login"
    }
  }

  public var noun: String {
    switch self {
    case .credential: "Credential"
    case .login: "Login"
    }
  }

  public var title: String { noun + "s" }

  public var searchPrompt: String { "Search \(title.lowercased())" }

  /// What the pills above the list choose between.
  public var pillsLabel: String { "Whose \(title.lowercased())" }

  public var noMatchText: String { "No \(title.lowercased()) match your search." }

  public var emptyText: String {
    switch self {
    case .credential: "None yet. The bot asks for one when a coding job needs it."
    case .login: "None yet. The bot asks for one when a desktop job needs to sign in."
    }
  }

  public var note: String {
    switch self {
    case .credential:
      "Coding jobs get a placeholder for each credential; the value only goes to its hosts. "
        + "Uses are kept for \(Self.useRetentionDays) days."
    case .login:
      "Desktop jobs fill a login only into https pages on its hosts, and never see its password. "
        + "Fills are kept for \(Self.useRetentionDays) days."
    }
  }

  public var deleteWarning: String {
    switch self {
    case .credential:
      "Requests with its placeholder stop working at once, and its uses are deleted. This cannot be undone."
    case .login: "Desktop jobs can no longer fill it, and its fills are deleted. This cannot be undone."
    }
  }

  public var usesLabel: String {
    switch self {
    case .credential: "Uses"
    case .login: "Fills"
    }
  }

  public func usesTitle(_ name: String) -> String {
    switch self {
    case .credential: "Uses of \(name)"
    case .login: "Fills of \(name)"
    }
  }

  public var usesDescription: String {
    switch self {
    case .credential: "Requests sent with the value in the last \(Self.useRetentionDays) days, newest first."
    case .login: "Fields desktop jobs filled in the last \(Self.useRetentionDays) days, newest first."
    }
  }

  public var usesEmptyText: String {
    switch self {
    case .credential: "Not used yet."
    case .login: "Not filled yet."
    }
  }

  private static let useRetentionDays = 90
}

public enum PasswordManagerID: String, CaseIterable, Codable, Hashable, Sendable {
  case onePassword = "1password"
  case bitwarden

  public var referencePlaceholder: String {
    switch self {
    case .onePassword: "op://vault/item/field"
    case .bitwarden: "Secret ID"
    }
  }

  public var tokenLabel: String {
    switch self {
    case .onePassword: "Service account token"
    case .bitwarden: "Access token"
    }
  }
}

public struct PasswordManager: Identifiable, Hashable, Sendable {
  public var id: PasswordManagerID
  public var name: String
  public var connected: Bool
  /// The secrets that read from it. It can't be disconnected while any remain.
  public var usedBy: [String]

  public init(id: PasswordManagerID, name: String, connected: Bool, usedBy: [String] = []) {
    self.id = id
    self.name = name
    self.connected = connected
    self.usedBy = usedBy
  }
}

/// Where a saved secret is read from. The value itself never comes back from the server.
public struct SecretStatus: Codable, Hashable, Sendable {
  public var configured: Bool
  public var passwordManager: PasswordManagerID?
  public var reference: String?

  public init(configured: Bool, passwordManager: PasswordManagerID? = nil, reference: String? = nil) {
    self.configured = configured
    self.passwordManager = passwordManager
    self.reference = reference
  }
}

/// A saved credential or login, without its value.
public struct BotSecret: Identifiable, Hashable, Sendable {
  public var kind: BotSecretKind
  public var name: String
  public var hosts: [String]
  /// A credential's value; null for a GitHub token.
  public var secret: SecretStatus?
  public var username: SecretStatus?
  public var password: SecretStatus?
  public var oneTimeCode: SecretStatus?
  public var lastUsedAt: String?
  public var lastError: String?
  /// A GitHub token follows its App or machine account; the server refuses to change it here.
  public var managed = false

  public var id: String { name }

  public init(kind: BotSecretKind, name: String, hosts: [String]) {
    self.kind = kind
    self.name = name
    self.hosts = hosts
  }

  /// Why the newest use failed, or when it was.
  public func lastUse(now: Date = .now) -> String {
    if let lastError { return lastError }
    let used = kind == .credential ? "Used" : "Filled"
    guard let date = lastUsedAt.flatMap(taskRunDate) else {
      return kind == .credential ? "Never used" : "Never filled"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return used + " " + formatter.localizedString(for: date, relativeTo: now)
  }
}

/// What a bot asks the owner to add.
public struct BotSecretRequest: Identifiable, Hashable, Sendable {
  public var name: String
  public var hosts: [String]
  public var reason: String
  /// Whether the bot says the site asks for a one-time code.
  public var oneTimeCode = false
  public var requestedAt: String

  public var id: String { name }

  public init(name: String, hosts: [String], reason: String, oneTimeCode: Bool = false, requestedAt: String) {
    self.name = name
    self.hosts = hosts
    self.reason = reason
    self.oneTimeCode = oneTimeCode
    self.requestedAt = requestedAt
  }
}

/// A bot's saved credentials or logins and what it still waits for. A saved one and a request for
/// more under its name can coexist.
public struct BotSecretList: Hashable, Sendable {
  public var items: [BotSecret] = []
  public var requests: [BotSecretRequest] = []

  public init(items: [BotSecret] = [], requests: [BotSecretRequest] = []) {
    self.items = items
    self.requests = requests
  }
}

/// A request sent with a credential's value, or a field a desktop job filled.
public struct BotSecretUse: Identifiable, Hashable, Sendable {
  public var id: String
  public var usedAt: String
  public var summary: String
  public var outcome: String?
  public var failed: Bool

  public init(id: String, usedAt: String, summary: String, outcome: String?, failed: Bool) {
    self.id = id
    self.usedAt = usedAt
    self.summary = summary
    self.outcome = outcome
    self.failed = failed
  }
}

/// A `request_credential` or `request_login` result in the chat. It says what was asked; whether it
/// still waits is in the bot's list.
public struct BotSecretAsk: Hashable, Sendable {
  public var kind: BotSecretKind
  public var name: String
  public var hosts: [String]
  public var requestedAt: String?

  public init?(message: Message) {
    guard message.role == "toolResult", message.isError != true,
      let kind = BotSecretKind.allCases.first(where: { $0.toolName == message.toolName }),
      case .object(let details)? = message.toolDetails,
      case .string(let name)? = details["name"], !name.isEmpty
    else { return nil }
    self.kind = kind
    self.name = name
    if case .array(let hosts)? = details["hosts"] {
      self.hosts = hosts.compactMap {
        if case .string(let host) = $0 { host } else { nil }
      }
    } else {
      hosts = []
    }
    if case .string(let requestedAt)? = details["requestedAt"] { self.requestedAt = requestedAt }
  }

  func matches(_ request: BotSecretRequest) -> Bool {
    request.name == name && (requestedAt == nil || requestedAt == request.requestedAt)
  }
}

extension SecretStatus {
  init(wire: Components.Schemas.SecretStatus) {
    configured = wire.configured
    reference = wire.reference
    passwordManager = switch wire.passwordManager {
    case ._1password: .onePassword
    case .bitwarden: .bitwarden
    case ._empty_, nil: nil
    }
  }
}

extension BotSecret {
  init(wire: Components.Schemas.Credential) {
    self.init(kind: .credential, name: wire.name, hosts: wire.hosts)
    secret = wire.secret.map { SecretStatus(wire: $0.value1) }
    lastUsedAt = wire.lastUsedAt
    lastError = wire.lastError
    managed = wire.github
  }

  init(wire: Components.Schemas.Login) {
    self.init(kind: .login, name: wire.name, hosts: wire.hosts)
    username = wire.fields.username.map(SecretStatus.init(wire:))
    password = wire.fields.password.map(SecretStatus.init(wire:))
    oneTimeCode = wire.fields.oneTimeCode.map(SecretStatus.init(wire:))
    lastUsedAt = wire.lastUsedAt
    lastError = wire.lastError
  }
}

extension BotSecretUse {
  init(wire: Components.Schemas.CredentialUse) {
    self.init(
      id: wire.id, usedAt: wire.at, summary: "\(wire.method) \(wire.host)\(wire.path)",
      outcome: wire.status.map(String.init) ?? wire.error ?? "failed", failed: wire.status == nil)
  }

  init(wire: Components.Schemas.LoginUse) {
    let field = switch wire.field {
    case .username: "Username"
    case .password: "Password"
    case .oneTimeCode: "One-time code"
    }
    self.init(
      id: wire.id, usedAt: wire.at, summary: "\(field) on \(wire.host)", outcome: wire.error,
      failed: wire.error != nil)
  }
}
