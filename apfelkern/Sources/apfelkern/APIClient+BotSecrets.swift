import Foundation

struct SecretBody: Encodable {
  struct Reference: Encodable {
    var passwordManager: String
    var reference: String
  }

  var value: String?
  var reference: Reference?

  init(_ input: SecretInput) {
    switch input {
    case .value(let value): self.value = value
    case .reference(let manager, let reference):
      self.reference = Reference(passwordManager: manager.rawValue, reference: reference)
    }
  }
}

private struct CredentialBody: Encodable {
  var hosts: [String]
  var secret: SecretBody?
}

private struct LoginFields: Encodable {
  var username: SecretBody?
  var password: SecretBody?
  var oneTimeCode: SecretBody?

  enum CodingKeys: String, CodingKey {
    case username, password
    case oneTimeCode = "one_time_code"
  }
}

private struct LoginBody: Encodable {
  struct Item: Encodable {
    var passwordManager = PasswordManagerID.onePassword.rawValue
    var reference: String
  }

  var hosts: [String]
  var item: Item?
  var fields: LoginFields?
}

extension APIClient {
  public func botSecrets(_ kind: BotSecretKind, agentID: String) async throws -> BotSecretList {
    try await invoke {
      switch kind {
      case .credential:
        let list = try await $0.listAgentCredentials(.init(path: .init(id: agentID))).ok.body.json
        return BotSecretList(
          items: list.credentials.map(BotSecret.init(wire:)),
          requests: list.requests.map {
            BotSecretRequest(name: $0.name, hosts: $0.hosts, reason: $0.reason, requestedAt: $0.requestedAt)
          })
      case .login:
        let list = try await $0.listAgentLogins(.init(path: .init(id: agentID))).ok.body.json
        return BotSecretList(
          items: list.logins.map(BotSecret.init(wire:)),
          requests: list.requests.map {
            BotSecretRequest(
              name: $0.name, hosts: $0.hosts, reason: $0.reason, oneTimeCode: $0.oneTimeCode,
              requestedAt: $0.requestedAt)
          })
      }
    }
  }

  /// Creates or updates what the draft holds. The server checks a password manager can read a
  /// reference before it answers, so this can take longer than a plain save.
  func saveBotSecret(_ draft: BotSecretDraft) async throws -> BotSecret {
    switch draft.kind {
    case .credential: try await saveCredential(draft)
    case .login: try await saveLogin(draft)
    }
  }

  private func saveCredential(_ draft: BotSecretDraft) async throws -> BotSecret {
    let body: Operations.SaveAgentCredential.Input.Body.JsonPayload = try requestModel(CredentialBody(
      hosts: draft.hostList, secret: draft.value.changedInput.map(SecretBody.init)))
    return try await invoke(timeout: 60) {
      BotSecret(wire: try await $0.saveAgentCredential(
        .init(path: .init(id: draft.agentID, name: draft.name), body: .json(body))).ok.body.json)
    }
  }

  private func saveLogin(_ draft: BotSecretDraft) async throws -> BotSecret {
    let payload = if draft.usesItem {
      LoginBody(hosts: draft.hostList, item: .init(reference: draft.trimmedItem))
    } else {
      LoginBody(hosts: draft.hostList, fields: .init(
        username: draft.username.changedInput.map(SecretBody.init),
        password: draft.password.changedInput.map(SecretBody.init),
        oneTimeCode: draft.hasCode ? draft.oneTimeCode.changedInput.map(SecretBody.init) : nil))
    }
    let body: Operations.SaveAgentLogin.Input.Body.JsonPayload = try requestModel(payload)
    let cleared: Set<String> = !draft.usesItem && draft.removesCode ? ["fields.one_time_code"] : []
    return try await invoke(timeout: 60, nullFields: cleared) {
      BotSecret(wire: try await $0.saveAgentLogin(
        .init(path: .init(id: draft.agentID, name: draft.name), body: .json(body))).ok.body.json)
    }
  }

  public func deleteBotSecret(_ kind: BotSecretKind, agentID: String, name: String) async throws {
    try await invoke {
      switch kind {
      case .credential:
        _ = try await $0.deleteAgentCredential(.init(path: .init(id: agentID, name: name))).noContent
      case .login:
        _ = try await $0.deleteAgentLogin(.init(path: .init(id: agentID, name: name))).noContent
      }
    }
  }

  /// Never a delete: a saved item and a request for more under its name can coexist.
  public func declineBotSecret(_ kind: BotSecretKind, agentID: String, name: String) async throws {
    try await invoke {
      switch kind {
      case .credential:
        _ = try await $0.declineAgentCredential(.init(path: .init(id: agentID, name: name))).noContent
      case .login:
        _ = try await $0.declineAgentLogin(.init(path: .init(id: agentID, name: name))).noContent
      }
    }
  }

  /// One page, newest first. `before` is the last use of the page above.
  public func botSecretUses(_ kind: BotSecretKind, agentID: String, name: String, before: String, limit: Int)
    async throws -> [BotSecretUse] {
    try await invoke {
      switch kind {
      case .credential:
        try await $0.listAgentCredentialUses(.init(
          path: .init(id: agentID, name: name), query: .init(limit: limit, before: before.nilIfEmpty)
        )).ok.body.json.map(BotSecretUse.init(wire:))
      case .login:
        try await $0.listAgentLoginUses(.init(
          path: .init(id: agentID, name: name), query: .init(limit: limit, before: before.nilIfEmpty)
        )).ok.body.json.map(BotSecretUse.init(wire:))
      }
    }
  }
}
