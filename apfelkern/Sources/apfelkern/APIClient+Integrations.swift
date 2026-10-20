import Foundation

extension APIClient {
  public func providers() async throws -> [ProviderStatus] {
    try await invoke {
      try await $0.listProviders(.init()).ok.body.json.map {
        ProviderStatus(provider: $0.provider, name: $0.name, configured: $0.configured)
      }
    }
  }

  public func models(provider: String) async throws -> [ModelSummary] {
    try await invoke {
      try await $0.listModels(.init(query: .init(provider: provider))).ok.body.json.map {
        ModelSummary(provider: $0.provider, id: $0.id, name: $0.name,
                     contextWindow: Int(exactly: $0.contextWindow), reasoning: $0.reasoning)
      }
    }
  }

  public func setProviderKey(_ provider: String, apiKey: String) async throws {
    try await invoke {
      _ = try await $0.putProviderKey(.init(
        path: .init(provider: provider), body: .json(.init(apiKey: apiKey)))).ok
    }
  }

  public func deleteProviderKey(_ provider: String) async throws {
    try await invoke { _ = try await $0.deleteProviderKey(.init(path: .init(provider: provider))).noContent }
  }

  public func mcpServers() async throws -> [MCPServer] {
    try await invoke { try await $0.listMcpServers(.init()).ok.body.json.map(MCPServer.init(wire:)) }
  }

  public func createMCPServer(_ payload: [String: JSONValue]) async throws -> MCPServer {
    let body: Operations.CreateMcpServer.Input.Body.JsonPayload = try requestModel(payload)
    return try await invoke(nullFields: Set(payload.filter { $0.value == .null }.keys)) {
      try MCPServer(wire: await $0.createMcpServer(.init(body: .json(body))).created.body.json)
    }
  }

  public func updateMCPServer(_ id: String, patch: [String: JSONValue]) async throws -> MCPServer {
    let body: Operations.UpdateMcpServer.Input.Body.JsonPayload = try requestModel(patch)
    return try await invoke {
      MCPServer(wire: try requestModel(required(try await $0.updateMcpServer(
        .init(path: .init(id: id), body: .json(body))).ok.body.json)) as Components.Schemas.McpServer)
    }
  }

  public func deleteMCPServer(_ id: String) async throws {
    try await invoke { _ = try await $0.deleteMcpServer(.init(path: .init(id: id))).noContent }
  }

  public func startMCPSignIn(_ id: String, redirectURI: String) async throws -> OAuthStart {
    try await invoke(timeout: 60) {
      let wire = try await $0.startMcpOAuth(.init(
        path: .init(id: id), body: .json(.init(redirectUri: redirectURI)))).ok.body.json
      return OAuthStart(authorizationUrl: wire.value1?.authorizationUrl, authorized: wire.value2?.authorized)
    }
  }

  public func finishMCPSignIn(_ id: String, code: String, state: String, iss: String?) async throws -> MCPServer {
    try await invoke(timeout: 60) {
      try MCPServer(wire: await $0.finishMcpOAuth(.init(
        path: .init(id: id), body: .json(.init(code: code, iss: iss, state: state)))).ok.body.json)
    }
  }

  public func signOutOfMCP(_ id: String) async throws -> MCPServer {
    try await invoke { try MCPServer(wire: await $0.signOutMcpOAuth(.init(path: .init(id: id))).ok.body.json) }
  }
}
