import Foundation

/// A GitHub identity the owner created on one GitHub account and assigned to bots.
public struct GitHubApp: Identifiable, Hashable, Sendable {
  public var id: String
  public var slug: String
  public var name: String
  /// The name commits and pull requests show, such as `scout[bot]`.
  public var login: String
  public var htmlUrl: String
  public var installUrl: String
  /// The GitHub user or organization whose repositories the App works on.
  public var account: String?
  public var installed: Bool
  public var clientSecret: SecretStatus
  /// The owner's GitHub login when signed in through the App.
  public var user: String?
  public var botIds: [String]

  public var usedByText: String {
    user.map { "As \($0), used by \(botIds.count)" } ?? "Used by \(botIds.count)"
  }
  public var installationText: String {
    if installed { return "Installed on \(account ?? "GitHub")" }
    return account.map { "Not installed on \($0)" } ?? "Not installed"
  }
  public var removeWarning: String {
    "Its bots lose access to GitHub through it. The App stays on GitHub; delete it in its settings there."
  }
  public var actsAsText: String { user.map { "\($0), marked as \(login)" } ?? login }
  public var signedInNote: String {
    "GitHub shows their pull requests and comments with the App's badge, and their commits list \(login) "
      + "as co-author."
  }
}

extension GitHubApp {
  init(wire: Components.Schemas.GitHubApp) {
    self.init(
      id: wire.id, slug: wire.slug, name: wire.name, login: wire.login, htmlUrl: wire.htmlUrl,
      installUrl: wire.installUrl, account: wire.account, installed: wire.installed,
      clientSecret: SecretStatus(wire: wire.clientSecret), user: wire.user, botIds: wire.botIds)
  }
}

/// What `createGitHubAppManifest` hands the browser: a form to post to `url`.
struct GitHubAppManifest: Sendable {
  var url: String
  var manifest: String
}

/// The form for a new App. Creating it happens on GitHub, so nothing here is saved yet.
public struct NewGitHubAppDraft: Identifiable, Sendable {
  public static let maxNameCharacters = 34

  public let id = UUID()
  public var name = "" {
    didSet { if name.count > Self.maxNameCharacters { name = String(name.prefix(Self.maxNameCharacters)) } }
  }
  public var organization = ""

  public init() {}

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmedOrganization: String? {
    let trimmed = organization.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public var isReady: Bool { !trimmedName.isEmpty }
}

/// The sheet for one App. The client secret stays write-only: it leaves only in a save request.
public struct GitHubAppDraft: Identifiable, Sendable {
  public let id = UUID()
  /// Follows the server, so the sheet shows an installation or sign-in that finishes while it's open.
  public internal(set) var app: GitHubApp
  public var botIDs: Set<String>
  public var clientSecret: SecretSourceDraft

  public init(app: GitHubApp) {
    self.app = app
    botIDs = Set(app.botIds)
    clientSecret = SecretSourceDraft(saved: app.clientSecret)
  }

  var changesBots: Bool { botIDs != Set(app.botIds) }

  public var canSaveClientSecret: Bool { clientSecret.changedInput != nil }

  mutating func clientSecretSaved(_ saved: GitHubApp) {
    app = saved
    clientSecret = SecretSourceDraft(saved: saved.clientSecret)
  }

  /// Strings can't be wiped in place; this drops the draft's references to the typed secret.
  public mutating func clearSecrets() {
    clientSecret.clear()
  }
}

extension GitHubAppDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "GitHubAppDraft(\(app.login))" }
  public var customMirror: Mirror { Mirror(self, children: ["login": app.login]) }
}

/// A step the owner finishes in the system browser, and the address to send them to.
public struct GitHubTrip: Identifiable, Equatable, Sendable {
  public enum Step: Equatable, Sendable {
    case create
    case install(appID: String)
    case signIn(appID: String)
  }

  public let id = UUID()
  public let step: Step
  public let url: URL

  /// How long the server keeps the step's state, so how long waiting can succeed.
  var lifetime: Duration {
    switch step {
    case .create: .seconds(60 * 60)
    case .install, .signIn: .seconds(10 * 60)
    }
  }

  var appID: String? {
    switch step {
    case .create: nil
    case let .install(appID), let .signIn(appID): appID
    }
  }

  public var progressText: String {
    switch step {
    case .create: "Waiting for GitHub to create the App…"
    case .install: "Waiting for GitHub to install the App…"
    case .signIn: "Waiting for GitHub to sign you in…"
    }
  }

  /// The web page only knows about installs it started itself, so it rejects this one.
  public var browserNote: String? {
    guard case .install = step else { return nil }
    return "The web page GitHub returns to may say the link is incomplete. "
      + "That's expected: Crumble confirms the installation here."
  }
}
