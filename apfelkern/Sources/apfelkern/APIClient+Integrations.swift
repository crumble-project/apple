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
                     contextWindow: Int(exactly: $0.contextWindow), reasoning: $0.reasoning,
                     thinkingLevels: $0.thinkingLevels.compactMap { ThinkingLevel(rawValue: $0.rawValue) })
      }
    }
  }

  public func mcpServers() async throws -> [MCPServer] {
    try await invoke { try await $0.listMcpServers(.init()).ok.body.json.map(MCPServer.init(wire:)) }
  }
}
