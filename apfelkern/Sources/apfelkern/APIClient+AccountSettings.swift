import Foundation

extension ModelRef {
  init(wire: Components.Schemas.JudgeModel.JudgeModelPayload) {
    self.init(provider: wire.provider, model: wire.model)
  }

  init(wire: Components.Schemas.VisionModel.VisionModelPayload) {
    self.init(provider: wire.provider, model: wire.model)
  }
}

extension VisionModelSettings {
  init(wire: Components.Schemas.VisionModel) {
    self.init(
      visionModel: wire.visionModel.map(ModelRef.init(wire:)),
      choices: wire.choices.map {
        ModelChoice(ref: ModelRef(provider: $0.provider, model: $0.model), name: $0.name)
      })
  }
}

extension APIClient {
  public func webSearch() async throws -> WebSearchSettings {
    try await invoke {
      let wire = try await $0.getWebSearch(.init()).ok.body.json
      return WebSearchSettings(
        defaultProvider: try required(WebSearchProvider(rawValue: wire.defaultProvider.rawValue)),
        exaKeyConfigured: wire.exaKeyConfigured)
    }
  }

  public func updateWebSearch(defaultProvider: WebSearchProvider) async throws -> WebSearchSettings {
    let provider = try required(
      Operations.UpdateWebSearch.Input.Body.JsonPayload.DefaultProviderPayload(rawValue: defaultProvider.rawValue))
    return try await invoke {
      let wire = try await $0.updateWebSearch(.init(body: .json(.init(defaultProvider: provider)))).ok.body.json
      return WebSearchSettings(
        defaultProvider: try required(WebSearchProvider(rawValue: wire.defaultProvider.rawValue)),
        exaKeyConfigured: wire.exaKeyConfigured)
    }
  }

  public func judgeModel() async throws -> JudgeModelSettings {
    try await invoke { try judgeSettings(try await $0.getJudgeModel(.init()).ok.body.json) }
  }

  /// A nil model goes back to the default.
  public func updateJudgeModel(_ model: ModelRef?) async throws -> JudgeModelSettings {
    try await invoke(nullFields: model == nil ? ["judgeModel"] : []) {
      try judgeSettings(try await $0.updateJudgeModel(.init(body: .json(.init(
        judgeModel: model.map { .init(model: $0.model, provider: $0.provider) })))).ok.body.json)
    }
  }

  public func visionModel() async throws -> VisionModelSettings {
    try await invoke { VisionModelSettings(wire: try await $0.getVisionModel(.init()).ok.body.json) }
  }

  /// A nil model turns it off. Any other must be one of the setting's choices.
  public func updateVisionModel(_ model: ModelRef?) async throws -> VisionModelSettings {
    try await invoke(nullFields: model == nil ? ["visionModel"] : []) {
      VisionModelSettings(wire: try await $0.updateVisionModel(.init(body: .json(.init(
        visionModel: model.map { .init(model: $0.model, provider: $0.provider) })))).ok.body.json)
    }
  }
  private func judgeSettings(_ wire: Components.Schemas.JudgeModel) throws -> JudgeModelSettings {
    JudgeModelSettings(
      judgeModel: wire.judgeModel.map(ModelRef.init(wire:)), effective: try wire.effective.map(judgeChoice),
      choices: try wire.choices.map(judgeChoice))
  }

  private func judgeChoice(_ wire: Components.Schemas.JudgeChoice) throws -> JudgeChoice {
    JudgeChoice(
      choice: ModelChoice(ref: ModelRef(provider: wire.provider, model: wire.model), name: wire.name),
      kind: try required(JudgeKind(rawValue: wire.kind.rawValue)))
  }
}
