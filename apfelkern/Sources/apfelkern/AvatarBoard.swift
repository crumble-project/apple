import Foundation
import Observation

/// Saves through the app's pending mutations, so a bot list read before the save can't undo it.
@MainActor
public protocol AvatarHost: AnyObject {
  var agents: [Agent] { get set }

  func optimisticMutation(
    key: String,
    update: () -> Void,
    rollback: @escaping @MainActor () -> Void,
    work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  )
}

/// The standalone Avatars page: a definition to preview and, with a bot chosen, to save to it. Saving
/// shows on the bot at once and rolls back on failure, keeping the definition here to try again.
/// Saved shows only once the server has it. Results after the connection changed are dropped.
@MainActor @Observable
public final class AvatarBoard {
  /// The bot being edited, or empty to only preview.
  public private(set) var botID = ""
  public var value = BotAvatarDefinition.default(for: "crumble") {
    didSet {
      saved = false
      saveError = ""
    }
  }
  public private(set) var isSaving = false
  public private(set) var saved = false
  public private(set) var saveError = ""

  public init() {}

  public func reset() {
    botID = ""
    value = BotAvatarDefinition.default(for: "crumble")
    isSaving = false
  }

  /// Starts from the bot's avatar; choosing nobody keeps the current preview.
  public func select(_ bot: Agent?) {
    botID = bot?.id ?? ""
    if let bot { value = bot.avatar }
    saved = false
    saveError = ""
  }

  /// A deleted bot can't be saved to, so its page falls back to preview.
  public func keepSelection(in botIDs: [String]) {
    if !botID.isEmpty, !botIDs.contains(botID) { select(nil) }
  }

  public var canSave: Bool { !botID.isEmpty && !isSaving }

  /// A write can't be cancelled, so a second waits for it: they could land out of order. The error
  /// stays on this page, so a failure settles inside `work` instead of raising the app's banner.
  public func save(to host: some AvatarHost) {
    guard canSave, let bot = host.agents.first(where: { $0.id == botID }) else { return }
    let id = bot.id
    let previous = bot.avatar
    let sent = value
    let show = { (avatar: BotAvatarDefinition) in
      if let index = host.agents.firstIndex(where: { $0.id == id }) { host.agents[index].avatar = avatar }
    }
    host.optimisticMutation(
      key: "avatar:\(id)",
      update: { [self] in
        isSaving = true
        saveError = ""
        show(sent)
      },
      rollback: {},
      work: { [self] client in
        do {
          let updated = try await client.updateAgent(id, patch: ["avatar": try JSONValue(encoding: sent)])
          return { [self] in
            isSaving = false
            show(updated.avatar)
            saved = botID == id && value == sent
          }
        } catch {
          return { [self] in
            isSaving = false
            show(previous)
            saveError = friendlyError(error)
          }
        }
      })
  }
}
