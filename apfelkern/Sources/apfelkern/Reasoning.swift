import Observation

/// How much a bot reasons before it answers, lowest first as in the contract.
public enum ThinkingLevel: String, CaseIterable, Codable, Identifiable, Sendable {
  case off, minimal, low, medium, high, xhigh, max

  public var id: String { rawValue }
}

/// A level a model offers, with the server's label for it.
public struct ReasoningOption: Hashable, Identifiable, Sendable {
  public var level: ThinkingLevel
  public var label: String

  public var id: ThinkingLevel { level }

  public init(level: ThinkingLevel, label: String) {
    self.level = level
    self.label = label
  }
}

/// The server's reasoning policy for a model: the levels it offers and the one a turn runs at, which a model
/// that lacks the chosen level clamps.
public struct ReasoningPreview: Hashable, Sendable {
  public var options: [ReasoningOption]
  public var effectiveLevel: ThinkingLevel

  public init(options: [ReasoningOption], effectiveLevel: ThinkingLevel) {
    self.options = options
    self.effectiveLevel = effectiveLevel
  }

  public var label: String { options.first { $0.level == effectiveLevel }?.label ?? effectiveLevel.rawValue }
}

/// The server's reasoning previews for the composer's control and the bot form. A choice in the composer shows
/// on the bot at once and rolls back if the server refuses it. Previews from an earlier connection are dropped.
@MainActor @Observable
public final class ReasoningBoard {
  private struct Key: Hashable {
    var provider: String
    var model: String
    var level: ThinkingLevel
  }

  /// The server's previews on this connection; a model's levels change only with the server.
  private var previews: [Key: ReasoningPreview] = [:]
  private var connection = 0
  /// Bots with a write on its way; a second could land out of order.
  public private(set) var saving: Set<String> = []

  public init() {}

  public func reset() {
    connection += 1
    previews = [:]
    saving = []
  }

  private static func key(provider: String?, model: String?, level: String) -> Key? {
    guard let provider = provider?.nilIfEmpty else { return nil }
    return Key(
      provider: provider, model: model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      level: ThinkingLevel(rawValue: level) ?? .off)
  }

  /// Nil until the server answers, which keeps a reasoning control hidden. Meanwhile a level the server
  /// offered for the same model shows as itself, so a choice doesn't hide the control while it loads.
  public func preview(provider: String?, model: String?, level: String) -> ReasoningPreview? {
    guard let key = Self.key(provider: provider, model: model, level: level) else { return nil }
    if let preview = previews[key] { return preview }
    let offered = previews.first { other, preview in
      other.provider == key.provider && other.model == key.model && preview.options.contains { $0.level == key.level }
    }
    return offered.map { ReasoningPreview(options: $0.value.options, effectiveLevel: key.level) }
  }

  public func preview(of bot: Agent) -> ReasoningPreview? {
    preview(provider: bot.provider, model: bot.model, level: bot.inference?.thinkingLevel ?? "off")
  }

  /// Asks the server once the inputs have held for `delay`. Cancelling the task, as SwiftUI does when its
  /// inputs change, drops the request and any late answer. A failed request shows no preview.
  public func load(
    provider: String?, model: String?, level: String, client: APIClient, after delay: Duration = .milliseconds(250)
  ) async {
    guard let key = Self.key(provider: provider, model: model, level: level), previews[key] == nil else { return }
    let loadedFor = connection
    try? await Task.sleep(for: delay)
    guard !Task.isCancelled, loadedFor == connection,
      let loaded = try? await client.previewReasoning(provider: key.provider, model: key.model, level: key.level),
      !Task.isCancelled, loadedFor == connection
    else { return }
    previews[key] = loaded
  }

  public func load(bot: Agent, client: APIClient, after delay: Duration = .milliseconds(250)) async {
    await load(
      provider: bot.provider, model: bot.model, level: bot.inference?.thinkingLevel ?? "off", client: client,
      after: delay)
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
