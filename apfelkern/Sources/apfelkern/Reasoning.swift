import Foundation
import Observation

public typealias ThinkingLevel = Components.Schemas.ReasoningOption.ValuePayload

/// The reasoning control in a bot chat's composer. A choice shows on the bot at once and rolls back if the
/// server refuses it. Previews from an earlier connection are dropped.
@MainActor @Observable
public final class ReasoningBoard {
  private var previews: [String: Components.Schemas.ReasoningPreview] = [:]
  private var previewKeys: [String: String] = [:]
  private var previewLevels: [String: String] = [:]
  private var connection = 0
  private var requests: [String: UUID] = [:]
  public private(set) var pendingLevels: [String: String] = [:]
  /// Bots with a write on its way; a second could land out of order.
  public private(set) var saving: Set<String> = []

  public init() {}

  public func reset() {
    connection += 1
    previews = [:]
    previewKeys = [:]
    previewLevels = [:]
    requests = [:]
    pendingLevels = [:]
    saving = []
  }

  public func previewKey(of bot: Agent, client: APIClient?) -> String {
    optionKey(of: bot, client: client) + "\u{0}" + (bot.inference?.thinkingLevel ?? "off")
  }

  private func optionKey(of bot: Agent, client: APIClient?) -> String {
    [client?.baseURL ?? "", client?.token ?? "", bot.id, bot.provider ?? "", bot.model ?? ""].joined(separator: "\u{0}")
  }

  public func preview(of bot: Agent, client: APIClient?) -> Components.Schemas.ReasoningPreview? {
    guard previewKeys[bot.id] == optionKey(of: bot, client: client) else { return nil }
    let level = bot.inference?.thinkingLevel ?? "off"
    guard previewLevels[bot.id] == level || pendingLevels[bot.id] != nil else { return nil }
    return previews[bot.id]
  }

  public func loadPreview(bot: Agent, client: APIClient) async {
    let version = connection
    let key = optionKey(of: bot, client: client)
    let request = UUID()
    requests[bot.id] = request
    let level = bot.inference?.thinkingLevel ?? "off"
    let result = try? await client.previewReasoning(
      provider: bot.provider ?? "", model: bot.model ?? "", level: level)
    guard !Task.isCancelled, version == connection, requests[bot.id] == request, let result else { return }
    previewKeys[bot.id] = key
    previews[bot.id] = result
    previewLevels[bot.id] = level
    if !saving.contains(bot.id), pendingLevels[bot.id] == level { pendingLevels[bot.id] = nil }
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
        requests[id] = nil
        pendingLevels[id] = level.rawValue
        show(chosen)
      },
      rollback: { [self] in
        saving.remove(id)
        pendingLevels[id] = nil
        show(previous)
      },
      work: { [self] client in
        let updated = try await client.updateAgent(id, patch: ["inference": body])
        return { [self] in
          saving.remove(id)
          let level = updated.inference?.thinkingLevel ?? "off"
          pendingLevels[id] = previewLevels[id] == level ? nil : level
          show(updated.inference)
        }
      })
  }
}
