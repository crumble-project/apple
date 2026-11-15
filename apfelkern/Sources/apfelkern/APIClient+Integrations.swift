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

  /// The levels a model offers and the one a turn at `level` runs at. A model the server doesn't list
  /// offers every level.
  public func previewReasoning(provider: String, model: String, level: ThinkingLevel) async throws
    -> ReasoningPreview {
    try await invoke {
      let preview = try await $0.previewReasoning(.init(body: .json(.init(
        model: model, provider: provider, thinkingLevel: .init(rawValue: level.rawValue)
      )))).ok.body.json
      return ReasoningPreview(
        options: preview.options.compactMap { option in
          ThinkingLevel(rawValue: option.value.rawValue).map { ReasoningOption(level: $0, label: option.label) }
        },
        effectiveLevel: ThinkingLevel(rawValue: preview.effectiveLevel.rawValue) ?? level)
    }
  }

  public func mcpServers() async throws -> [MCPServer] {
    try await invoke { try await $0.listMcpServers(.init()).ok.body.json.map(MCPServer.init(wire:)) }
  }
}
