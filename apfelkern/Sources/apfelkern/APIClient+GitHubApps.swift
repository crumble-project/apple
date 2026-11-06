import Foundation

extension APIClient {
  /// The server's web UI, where GitHub sends the owner back: the contract takes only an http(s) origin.
  private var webOrigin: String {
    get throws {
      guard var components = URLComponents(string: baseURL) else { throw URLError(.badURL) }
      components.path = ""
      components.query = nil
      components.fragment = nil
      guard let origin = components.string else { throw URLError(.badURL) }
      return origin
    }
  }

  /// The web page that must be signed in, in the system browser, for GitHub's return to finish.
  public var webSignInURL: URL? { (try? webOrigin).flatMap { URL(string: $0 + "/connect") } }

  /// The callback URL an older App has to list on GitHub before sign-in works.
  public var gitHubAppCallbackURL: String? { (try? webOrigin).map { $0 + "/github-app/authorized" } }

  public func gitHubApps() async throws -> [GitHubApp] {
    try await invoke {
      try await $0.listGithubApps(.init()).ok.body.json.apps.map(GitHubApp.init(wire:))
    }
  }

  func createGitHubAppManifest(name: String, organization: String?) async throws -> GitHubAppManifest {
    let body = Operations.CreateGithubAppManifest.Input.Body.JsonPayload(
      name: name, organization: organization, origin: try webOrigin)
    return try await invoke {
      let manifest = try await $0.createGithubAppManifest(.init(body: .json(body))).ok.body.json
      return GitHubAppManifest(url: manifest.url, manifest: manifest.manifest)
    }
  }

  /// The server asks GitHub whether the App is installed; 409 until it is.
  func connectGitHubApp(appID: String) async throws -> GitHubApp {
    try await invoke(timeout: 60) {
      GitHubApp(wire: try await $0.connectGithubApp(.init(path: .init(id: appID))).ok.body.json)
    }
  }

  public func setGitHubAppBots(appID: String, botIDs: Set<String>) async throws -> GitHubApp {
    try await invoke {
      GitHubApp(wire: try await $0.setGithubAppBots(
        .init(path: .init(id: appID), body: .json(.init(botIds: botIDs.sorted())))).ok.body.json)
    }
  }

  public func deleteGitHubApp(appID: String) async throws {
    try await invoke {
      _ = try await $0.deleteGithubApp(.init(path: .init(id: appID))).noContent
    }
  }

  /// Where to send the owner. GitHub returns to the App's callback URL whatever origin says.
  func signInGitHubApp(appID: String) async throws -> URL {
    let origin = try webOrigin
    return try await invoke {
      let address = try await $0.signInGithubApp(
        .init(path: .init(id: appID), body: .json(.init(origin: origin)))).ok.body.json.url
      guard let url = URL(string: address) else { throw URLError(.badURL) }
      return url
    }
  }

  /// The server revokes the grant on GitHub before it answers.
  func signOutGitHubApp(appID: String) async throws -> GitHubApp {
    try await invoke(timeout: 60) {
      GitHubApp(wire: try await $0.signOutGithubApp(.init(path: .init(id: appID))).ok.body.json)
    }
  }

  /// The server asks a password manager for a reference before it answers.
  func setGitHubAppClientSecret(_ input: SecretInput, appID: String) async throws -> GitHubApp {
    let body: Operations.SetGithubAppClientSecret.Input.Body.JsonPayload = try requestModel(SecretBody(input))
    return try await invoke(timeout: 60) {
      GitHubApp(wire: try await $0.setGithubAppClientSecret(
        .init(path: .init(id: appID), body: .json(body))).ok.body.json)
    }
  }
}
