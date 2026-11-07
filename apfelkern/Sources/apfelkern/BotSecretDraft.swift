import Foundation

/// A secret on its way to the server.
enum SecretInput: Equatable, Sendable {
  case value(String)
  case reference(PasswordManagerID, String)
}

/// One secret in the editor: a value typed here, or where a password manager holds it. A value
/// stored in Crumble is never shown, so a saved one starts empty.
public struct SecretSourceDraft: Sendable {
  /// Null while the value is stored in Crumble.
  public private(set) var manager: PasswordManagerID?
  public var value = ""
  public var reference = ""
  let saved: SecretStatus?

  public init(saved: SecretStatus? = nil) {
    self.saved = saved
    if let saved, let manager = saved.passwordManager, let reference = saved.reference {
      self.manager = manager
      self.reference = reference
    }
  }

  public mutating func use(_ manager: PasswordManagerID?) {
    guard manager != self.manager else { return }
    self.manager = manager
    value = ""
    reference = ""
  }

  /// A placeholder for the value field: empty keeps what's saved.
  public var keepPlaceholder: String {
    saved?.configured == true && saved?.passwordManager == nil ? "Keep the saved value" : ""
  }

  /// Says where the value lives; `valueNote` overrides the note for a value stored in Crumble.
  public func note(managers: [PasswordManager], valueNote: String? = nil) -> String {
    guard let manager else { return valueNote ?? "Stored encrypted and never shown again." }
    let name = managers.first { $0.id == manager }?.name ?? "the password manager"
    return "Read from \(name) when it's used. Crumble checks it can read it when you save."
  }

  var input: SecretInput? {
    if let manager {
      let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : .reference(manager, trimmed)
    }
    return value.isEmpty ? nil : .value(value)
  }

  /// What to send, if anything: the saved reference isn't read again when other fields change.
  var changedInput: SecretInput? {
    if case .reference(let manager, let reference)? = input, manager == saved?.passwordManager,
      reference == saved?.reference {
      return nil
    }
    return input
  }

  var changesReference: Bool {
    if case .reference? = changedInput { true } else { false }
  }

  mutating func clear() {
    value = ""
    reference = ""
  }
}

extension SecretInput {
  var json: JSONValue {
    switch self {
    case .value(let value): .object(["value": .string(value)])
    case .reference(let manager, let reference):
      .object([
        "reference": .object(["passwordManager": .string(manager.rawValue), "reference": .string(reference)])
      ])
    }
  }
}

extension SecretSourceDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "SecretSourceDraft(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The editor for a credential or login. Values stay write-only: they leave only in a save request.
public struct BotSecretDraft: Identifiable, Sendable {
  public let id = UUID()
  public let kind: BotSecretKind
  /// Only a new one from the cross-bot pages can change it, through `choosesBot`.
  public var agentID: String
  public let choosesBot: Bool
  public let existing: BotSecret?
  public let request: BotSecretRequest?
  /// Credentials are environment variable names and logins are lowercase, as the server requires.
  public var name: String {
    didSet { name = kind == .credential ? name.uppercased() : name.lowercased() }
  }
  public var hosts: String
  public var value: SecretSourceDraft
  public var username: SecretSourceDraft
  public var password: SecretSourceDraft
  public var oneTimeCode: SecretSourceDraft
  public var hasCode: Bool
  /// A 1Password item fills the whole login, instead of a source for each field.
  public var usesItem = false
  public var item = ""

  public init(
    kind: BotSecretKind, agentID: String, choosesBot: Bool = false, existing: BotSecret? = nil,
    request: BotSecretRequest? = nil
  ) {
    self.kind = kind
    self.agentID = agentID
    self.choosesBot = choosesBot
    self.existing = existing
    self.request = request
    name = existing?.name ?? request?.name ?? ""
    hosts = (existing?.hosts ?? request?.hosts ?? []).joined(separator: ", ")
    value = SecretSourceDraft(saved: existing?.secret)
    username = SecretSourceDraft(saved: existing?.username)
    password = SecretSourceDraft(saved: existing?.password)
    oneTimeCode = SecretSourceDraft(saved: existing?.oneTimeCode)
    hasCode = existing?.oneTimeCode != nil || request?.oneTimeCode == true
  }

  public var title: String { existing.map { "Edit " + $0.name } ?? "New " + kind.noun }

  public var namePlaceholder: String { kind == .credential ? "ACME_TOKEN" : "github" }

  public var nameNote: String {
    kind == .credential ? "The environment variable coding jobs see." : "How desktop jobs refer to it."
  }

  public var hostsPlaceholder: String {
    kind == .credential ? "api.example.com, *.example.com" : "github.com, *.github.com"
  }

  public var hostsNote: String {
    switch (kind, request != nil) {
    case (.credential, true):
      "The bot proposed these. The value goes only to them, so check they belong to the service."
    case (.credential, false): "The value goes only to these hosts. *.example.com covers every subdomain."
    case (.login, true):
      "The bot proposed these. The login is filled only into https pages on them, "
        + "so check they belong to the site."
    case (.login, false): "Filled only into https pages on these hosts. *.example.com covers every subdomain."
    }
  }

  public var nameLocked: Bool { existing != nil || request != nil }

  public var nameIsValid: Bool {
    switch kind {
    case .credential: name.wholeMatch(of: /[A-Z_][A-Z0-9_]{0,63}/) != nil && !nameIsReserved
    case .login: name.wholeMatch(of: /[a-z0-9][a-z0-9._-]{0,63}/) != nil
    }
  }

  /// The workspace, its shell, or the credential proxy depend on these. Mirrors the contract's
  /// `credentialName`, which the OpenAPI document doesn't carry.
  private static let reservedNames: Set<String> = [
    "SSL_CERT_FILE", "GIT_SSL_CAINFO", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "NODE_EXTRA_CA_CERTS",
    "NODE_USE_ENV_PROXY", "PATH", "HOME", "USER", "SHELL", "PWD", "TERM", "LANG", "HOSTNAME", "TMPDIR",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "NODE_OPTIONS", "SSL_CERT_DIR", "LD_PRELOAD",
    "LD_LIBRARY_PATH"
  ]

  private var nameIsReserved: Bool {
    kind == .credential
      && (Self.reservedNames.contains(name) || name.hasPrefix("CRUMBLE_") || name.hasPrefix("GIT_CONFIG_"))
  }

  /// Why Add stays off for a name that otherwise looks right.
  public var nameError: String? { nameIsReserved ? "This name is reserved for the workspace." : nil }

  var hostList: [String] {
    hosts.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.lowercased() }
  }

  var trimmedItem: String { item.trimmingCharacters(in: .whitespacesAndNewlines) }

  public var isReady: Bool {
    guard nameIsValid, !hostList.isEmpty else { return false }
    if kind == .credential { return existing != nil || value.input != nil }
    if usesItem { return trimmedItem.wholeMatch(of: /op:\/\/[^\/]+\/[^\/]+/) != nil }
    if hasCode, existing?.oneTimeCode == nil, oneTimeCode.input == nil { return false }
    return existing != nil || (username.input != nil && password.input != nil)
  }

  /// Turning the code off removes a saved one from the login.
  var removesCode: Bool { !hasCode && existing?.oneTimeCode != nil }

  /// The server reads a new reference before it answers, so the outcome depends on a password
  /// manager. Everything else is a plain write.
  var checksPasswordManager: Bool {
    switch kind {
    case .credential: value.changesReference
    case .login:
      usesItem || username.changesReference || password.changesReference
        || (hasCode && oneTimeCode.changesReference)
    }
  }

  /// The row to show until the server answers.
  var provisional: BotSecret {
    var item = existing ?? BotSecret(kind: kind, name: name, hosts: [])
    item.hosts = hostList
    return item
  }

  /// Strings can't be wiped in place; this drops the draft's references to the typed values.
  public mutating func clearSecrets() {
    value.clear()
    username.clear()
    password.clear()
    oneTimeCode.clear()
  }
}

extension BotSecretDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "BotSecretDraft(\(kind.rawValue), \(name))" }
  public var customMirror: Mirror {
    Mirror(self, children: ["kind": kind, "agentID": agentID, "name": name])
  }
}
