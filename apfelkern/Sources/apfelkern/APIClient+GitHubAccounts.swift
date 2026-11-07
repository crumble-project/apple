import Foundation

extension APIClient {
  public func gitHubAccounts() async throws -> [GitHubAccount] {
    try await invoke {
      try await $0.listGithubAccounts(.init()).ok.body.json.accounts.map(GitHubAccount.init(wire:))
    }
  }

  /// Adds the user the token signs in as, or replaces the token of the draft's account. The server
  /// asks GitHub, and a password manager for a reference, before it answers.
  func saveGitHubAccountToken(_ input: SecretInput, accountID: String?) async throws -> GitHubAccount {
    let payload = SecretBody(input)
    if let accountID {
      let body: Operations.SetGithubAccountToken.Input.Body.JsonPayload = try requestModel(payload)
      return try await invoke(timeout: 60) {
        GitHubAccount(wire: try await $0.setGithubAccountToken(
          .init(path: .init(id: accountID), body: .json(body))).ok.body.json)
      }
    }
    let body: Operations.AddGithubAccount.Input.Body.JsonPayload = try requestModel(payload)
    return try await invoke(timeout: 60) {
      GitHubAccount(wire: try await $0.addGithubAccount(.init(body: .json(body))).ok.body.json)
    }
  }

  public func setGitHubAccountBots(accountID: String, botIDs: Set<String>) async throws -> GitHubAccount {
    try await invoke {
      GitHubAccount(wire: try await $0.setGithubAccountBots(
        .init(path: .init(id: accountID), body: .json(.init(botIds: botIDs.sorted())))).ok.body.json)
    }
  }

  public func deleteGitHubAccount(accountID: String) async throws {
    try await invoke {
      _ = try await $0.deleteGithubAccount(.init(path: .init(id: accountID))).noContent
    }
  }
}
