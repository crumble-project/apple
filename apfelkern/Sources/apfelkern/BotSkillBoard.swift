import Foundation
import Observation

/// Each bot's own skills. Writes apply at once and go through the skill routes, which keep a
/// skill's documents, provenance, and pin; a bot's inline `skills` list matches by name instead.
@MainActor @Observable
public final class BotSkillBoard {
  private var lists: [String: [BotSkill]] = [:]
  private var readErrors: [String: String] = [:]
  private var reads: [String: Int] = [:]
  /// Reads up to this one are ignored: they may predate a write.
  private var settledReads: [String: Int] = [:]
  private var writes: [String: Int] = [:]
  /// Skills with a write in flight. One at a time, so a late answer can't undo a newer edit.
  public private(set) var pending: Set<String> = []
  /// Why deleting or pinning failed, by bot.
  public private(set) var errors: [String: String] = [:]
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    lists = [:]
    readErrors = [:]
    reads = [:]
    settledReads = [:]
    writes = [:]
    pending = []
    errors = [:]
  }

  public func isLoaded(agentID: String) -> Bool { lists[agentID] != nil }

  public func readError(agentID: String) -> String? { readErrors[agentID] }

  public func skills(agentID: String) -> [BotSkill] { lists[agentID] ?? [] }

  public func skill(_ skillID: String, agentID: String) -> BotSkill? {
    lists[agentID]?.first { $0.id == skillID }
  }

  /// While a write runs this waits: the write reads the list again when it ends.
  public func refresh(agentID: String, client: APIClient) {
    guard writes[agentID, default: 0] == 0 else { return }
    let version = scope
    let read = reads[agentID, default: 0] + 1
    reads[agentID] = read
    Task {
      do {
        let loaded = try await client.botSkills(agentID: agentID)
        guard scope == version, read > settledReads[agentID, default: 0] else { return }
        settledReads[agentID] = read
        lists[agentID] = loaded
        readErrors[agentID] = nil
      } catch {
        guard scope == version, read > settledReads[agentID, default: 0] else { return }
        readErrors[agentID] = friendlyError(error)
      }
    }
  }

  /// Creates a skill when `skillID` is nil. Returns false when that skill has a write in flight.
  /// `onFailure` runs after the rollback, so the app can give the owner their draft back.
  @discardableResult
  public func save(
    agentID: String, skillID: String? = nil, name: String, instructions: String, client: APIClient,
    onFailure: @escaping @MainActor (String) -> Void
  ) -> Bool {
    guard let skillID else {
      create(agentID: agentID, name: name, instructions: instructions, client: client, onFailure: onFailure)
      return true
    }
    guard let old = skill(skillID, agentID: agentID), !pending.contains(skillID) else { return false }
    var edited = old
    edited.name = name
    edited.instructions = instructions
    replace(skillID, agentID: agentID, with: edited)
    write(
      old, client: client, rollback: { [self] in replace(skillID, agentID: agentID, with: old) },
      onFailure: onFailure,
      work: { [self] client in
        let saved = try await client.updateBotSkill(
          agentID: agentID, skillID: skillID, name: name, instructions: instructions)
        return { [self] in replace(skillID, agentID: agentID, with: saved) }
      })
    return true
  }

  private func create(
    agentID: String, name: String, instructions: String, client: APIClient,
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    let provisional = BotSkill(
      id: "pending-skill-" + UUID().uuidString, agentID: agentID, name: name, instructions: instructions)
    lists[agentID, default: []].append(provisional)
    write(
      provisional, client: client, rollback: { [self] in lists[agentID]?.removeAll { $0.id == provisional.id } },
      onFailure: onFailure,
      work: { [self] client in
        let saved = try await client.createBotSkill(agentID: agentID, name: name, instructions: instructions)
        return { [self] in replace(provisional.id, agentID: agentID, with: saved) }
      })
  }

  public func setPinned(_ skill: BotSkill, pinned: Bool, client: APIClient) {
    guard !pending.contains(skill.id) else { return }
    var edited = skill
    edited.pinned = pinned
    replace(skill.id, agentID: skill.agentID, with: edited)
    write(
      skill, client: client, rollback: { [self] in replace(skill.id, agentID: skill.agentID, with: skill) },
      work: { [self] client in
        let saved = try await client.setBotSkillPinned(agentID: skill.agentID, skillID: skill.id, pinned: pinned)
        return { [self] in replace(skill.id, agentID: skill.agentID, with: saved) }
      })
  }

  public func delete(_ skill: BotSkill, client: APIClient) {
    guard !pending.contains(skill.id), let index = lists[skill.agentID]?.firstIndex(where: { $0.id == skill.id })
    else { return }
    lists[skill.agentID]?.remove(at: index)
    write(
      skill, client: client,
      rollback: { [self] in
        let count = lists[skill.agentID]?.count ?? 0
        lists[skill.agentID, default: []].insert(skill, at: min(index, count))
      },
      work: { client in
        try await client.deleteBotSkill(agentID: skill.agentID, skillID: skill.id)
        return {}
      })
  }

  /// Takes skills a bulk action already deleted out of the lists, ignoring reads that predate it.
  func forget(_ skillIDs: Set<String>) {
    for agentID in lists.keys {
      lists[agentID]?.removeAll { skillIDs.contains($0.id) }
      settledReads[agentID] = reads[agentID, default: 0]
    }
  }

  private func replace(_ skillID: String, agentID: String, with skill: BotSkill) {
    guard let index = lists[agentID]?.firstIndex(where: { $0.id == skillID }) else { return }
    lists[agentID]?[index] = skill
  }

  private func write(
    _ skill: BotSkill, client: APIClient, rollback: @escaping @MainActor () -> Void,
    onFailure: (@MainActor (String) -> Void)? = nil,
    work: @escaping @MainActor (APIClient) async throws -> @MainActor () -> Void
  ) {
    let agentID = skill.agentID
    let version = scope
    pending.insert(skill.id)
    writes[agentID, default: 0] += 1
    settledReads[agentID] = reads[agentID, default: 0]
    errors[agentID] = nil
    Task {
      do {
        let confirm = try await work(client)
        guard scope == version else { return }
        confirm()
      } catch {
        guard scope == version else { return }
        rollback()
        let message = friendlyError(error)
        if let onFailure { onFailure(message) } else { errors[agentID] = message }
      }
      pending.remove(skill.id)
      writes[agentID, default: 0] -= 1
      refresh(agentID: agentID, client: client)
    }
  }
}
