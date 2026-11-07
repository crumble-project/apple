import Foundation

/// A machine account: a GitHub user the owner made for bots. Its token never leaves the server.
public struct GitHubAccount: Identifiable, Hashable, Sendable {
  public static let newTokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new")
  public static let addSigningKeyURL = URL(string: "https://github.com/settings/ssh/new")

  public var id: String
  public var login: String
  public var htmlUrl: String
  public var botIds: [String]
  public var token: SecretStatus
  /// The OpenSSH public key its commits are signed with.
  public var signingKey: String

  public var usedByText: String { "Used by \(botIds.count)" }
  public var removeWarning: String {
    "Crumble forgets its token and its bots stop acting as it. The user stays on GitHub; revoke the token there too."
  }
  public var signingKeyNote: String {
    "Commits its bots make are signed with this key. Add it to \(login) on GitHub as a signing key "
      + "so they show as verified."
  }
}

extension GitHubAccount {
  init(wire: Components.Schemas.GitHubAccount) {
    self.init(
      id: wire.id, login: wire.login, htmlUrl: wire.htmlUrl, botIds: wire.botIds,
      token: SecretStatus(wire: wire.token), signingKey: wire.signingKey)
  }
}

/// The editor for a machine account. The token stays write-only: it leaves only in a save request.
public struct GitHubAccountDraft: Identifiable, Sendable {
  public let id = UUID()
  public private(set) var existing: GitHubAccount?
  public var botIDs: Set<String>
  public var token: SecretSourceDraft

  public init(existing: GitHubAccount? = nil) {
    self.existing = existing
    botIDs = Set(existing?.botIds ?? [])
    token = SecretSourceDraft(saved: existing?.token)
  }

  public var title: String { existing?.login ?? "New Machine Account" }

  public var tokenLabel: String {
    existing == nil || existing?.token.passwordManager != nil ? "Token" : "Replace token"
  }

  public var isReady: Bool { existing != nil || token.input != nil }

  /// GitHub has to accept a new token, so the outcome depends on the server's check.
  var checksToken: Bool { token.changedInput != nil }

  var changesBots: Bool {
    guard let existing else { return false }
    return botIDs != Set(existing.botIds)
  }

  /// The server took the token, so a retry of what's left doesn't send it again.
  mutating func tokenSaved(_ account: GitHubAccount) {
    existing = account
    token = SecretSourceDraft(saved: account.token)
  }

  /// Strings can't be wiped in place; this drops the draft's references to the typed token.
  public mutating func clearSecrets() {
    token.clear()
  }
}

extension GitHubAccountDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "GitHubAccountDraft(\(existing?.login ?? "new"))" }
  public var customMirror: Mirror { Mirror(self, children: ["login": existing?.login ?? "new"]) }
}
