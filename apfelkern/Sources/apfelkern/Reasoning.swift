import Observation

/// How much a bot reasons before it answers, lowest first as in the contract.
public enum ThinkingLevel: String, CaseIterable, Codable, Identifiable, Sendable {
  case off, minimal, low, medium, high, xhigh, max

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .off: "Off"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra high"
    case .max: "Maximum"
    }
  }

  /// The level a turn runs at: the nearest supported one, preferring higher, as Pi AI's `clampThinkingLevel`.
  public func clamped(to levels: [ThinkingLevel]) -> ThinkingLevel {
    guard !levels.contains(self) else { return self }
    let lower = Self.allCases.prefix { $0 != self }
    let higher = Self.allCases.dropFirst(lower.count + 1)
    return higher.first(where: levels.contains) ?? lower.last(where: levels.contains) ?? levels.first ?? .off
  }
}

/// The reasoning control in a bot chat's composer. A choice shows on the bot at once and rolls back if the
/// server refuses it. Model lists from an earlier connection are dropped.
@MainActor @Observable
public final class ReasoningBoard {
  private var models: [String: [ModelSummary]] = [:]
  private var connection = 0
  /// Bots with a write on its way; a second could land out of order.
  public private(set) var saving: Set<String> = []

  public init() {}

  public func reset() {
    connection += 1
    models = [:]
    saving = []
  }

  /// Reads the provider's models again each time, because a new key or sign-in changes them.
  public func load(provider: String, client: APIClient) async {
    let loadedFor = connection
    let loaded = try? await client.models(provider: provider)
    guard !Task.isCancelled, loadedFor == connection else { return }
    models[provider] = loaded ?? models[provider] ?? []
  }

  /// Empty until the models arrive, which keeps the control hidden. As on the web, a model the server
  /// doesn't list offers every level.
  public func levels(of bot: Agent) -> [ThinkingLevel] {
    guard let provider = bot.provider, let models = models[provider] else { return [] }
    return models.first { $0.id == bot.model }?.thinkingLevels ?? ThinkingLevel.allCases
  }

  /// The level the bot's turns run at, which a model that lacks the saved one clamps.
  public func level(of bot: Agent) -> ThinkingLevel {
    let saved = bot.inference.flatMap { ThinkingLevel(rawValue: $0.thinkingLevel) } ?? .off
    return saved.clamped(to: levels(of: bot))
  }

  public func choose(_ level: ThinkingLevel, for id: String, host: some BotListHost) {
    guard !saving.contains(id), let bot = host.agents.first(where: { $0.id == id }) else { return }
    let previous = bot.inference
    var chosen = previous ?? Inference(thinkingLevel: level.rawValue)
    chosen.thinkingLevel = level.rawValue
    guard let body = try? JSONValue(encoding: chosen) else { return }
    let show = { (inference: Inference?) in
      if let index = host.agents.firstIndex(where: { $0.id == id }) { host.agents[index].inference = inference }
    }
    host.optimisticMutation(
      key: "reasoning:\(id)",
      update: { [self] in
        saving.insert(id)
        show(chosen)
      },
      rollback: { [self] in
        saving.remove(id)
        show(previous)
      },
      work: { [self] client in
        let updated = try await client.updateAgent(id, patch: ["inference": body])
        return { [self] in
          saving.remove(id)
          show(updated.inference)
        }
      })
  }
}
