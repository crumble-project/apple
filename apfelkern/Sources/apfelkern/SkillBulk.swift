import Foundation
import Observation

public enum BulkSkillAction: String, Identifiable, CaseIterable, Sendable {
  case update, assign, remove, delete

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .update: "Update"
    case .assign: "Assign to bots"
    case .remove: "Remove from bots"
    case .delete: "Delete"
    }
  }

  /// The button that confirms assigning or removing.
  public var confirmation: String { self == .assign ? "Assign" : "Remove" }

  /// What assigning or removing does.
  public var explanation: String {
    self == .assign
      ? "Shared skills are enabled. Bot-specific skills are copied; existing linked copies and their edits are kept."
      : "Shared skills are disabled. Only linked bot-specific copies are deleted, including edited copies; "
        + "same-name skills and the original are kept."
  }

  public func isDisabled(for picked: [SelectableSkill], hasBots: Bool) -> Bool {
    switch self {
    case .update: picked.allSatisfy { !$0.isInstalled }
    case .assign, .remove: !hasBots
    case .delete: false
    }
  }
}

extension [SelectableSkill] {
  public var labels: String { map(\.label).joined(separator: ", ") }

  /// Says which picked skills an update would skip.
  public var updateNote: String? {
    let skipped = filter { !$0.isInstalled }
    guard !skipped.isEmpty else { return nil }
    return "Update skips skills not installed from GitHub: \(skipped.labels)."
  }

  public var deleteWarning: String {
    "Delete: \(labels). Shared skills are removed from every bot. Existing bot-specific copies are kept. "
      + "This cannot be undone here."
  }
}

public struct BulkSkillMessage: Identifiable, Hashable, Sendable {
  public var id: String
  public var text: String

  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
}

public struct BulkSkillBot: Hashable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct BulkSkillResult: Sendable {
  public var failed: Set<String>
  public var messages: [BulkSkillMessage]
}

/// Runs a bulk action one skill at a time, so two operations never race on one bot's assignments.
func runBulkSkillAction(
  _ action: BulkSkillAction, picked: [SelectableSkill], bots: [BulkSkillBot], client: APIClient
) async -> BulkSkillResult {
  var failed = Set<String>()
  var messages: [BulkSkillMessage] = []
  let updates = action == .update ? await UpdateCheck(client: client) : nil
  for skill in picked {
    do {
      switch action {
      case .delete: try await delete(skill, client: client)
      case .assign, .remove:
        let outcome = await assign(skill, to: bots, assigned: action == .assign, client: client)
        messages += outcome.messages
        if outcome.failed { failed.insert(skill.id) }
      case .update:
        if let updates, let note = try await update(skill, updates: updates, client: client) {
          messages.append(BulkSkillMessage(id: "skipped:\(skill.id)", text: "Skipped \(skill.label): \(note)."))
        }
      }
    } catch {
      failed.insert(skill.id)
      messages.append(BulkSkillMessage(
        id: "failed:\(skill.id)", text: "Failed \(skill.label): \(friendlyError(error))"))
    }
  }
  let failures = failed.isEmpty ? "" : "; \(failed.count) failed and remain selected"
  let summary = "\(picked.count - failed.count) of \(picked.count) skills processed\(failures)."
  messages.insert(BulkSkillMessage(id: "summary", text: summary), at: 0)
  return BulkSkillResult(failed: failed, messages: messages)
}

private struct UpdateCheck {
  var catalog: [SharedSkill] = []
  var failures: [SkillCheckFailure] = []
  var error: (any Error)?

  init(client: APIClient) async {
    do {
      failures = try await client.checkSkillUpdates()
      catalog = try await client.sharedSkills()
    } catch {
      self.error = error
    }
  }
}

private struct BulkError: LocalizedError {
  var errorDescription: String?
}

private func delete(_ skill: SelectableSkill, client: APIClient) async throws {
  if let agentID = skill.agentID {
    try await client.deleteBotSkill(agentID: agentID, skillID: skill.id)
  } else {
    try await client.deleteSharedSkill(skill.id)
  }
}

/// Returns why the skill was skipped, if it was.
private func update(_ skill: SelectableSkill, updates: UpdateCheck, client: APIClient) async throws -> String? {
  guard skill.isInstalled else { return "not installed from GitHub" }
  if let error = updates.error { throw error }
  guard let current = updates.catalog.first(where: { $0.id == skill.id }), let origin = current.origin else {
    throw BulkError(errorDescription: "Installed skill no longer exists.")
  }
  let failure = updates.failures.first { $0.repository == origin.repository && $0.branch == origin.branch }
  if let failure { throw BulkError(errorDescription: failure.message) }
  guard current.update != nil else { return "already up to date" }
  _ = try await client.applySkillUpdate(skill.id)
  return nil
}

/// Different bots are independent: at most four requests run at once, and results keep the bots' order.
private func assign(
  _ skill: SelectableSkill, to bots: [BulkSkillBot], assigned: Bool, client: APIClient
) async -> (failed: Bool, messages: [BulkSkillMessage]) {
  var outcomes = [(failed: Bool, message: BulkSkillMessage?)?](repeating: nil, count: bots.count)
  await withTaskGroup(of: (Int, Bool, BulkSkillMessage?).self) { group in
    for (index, bot) in bots.enumerated() {
      if index >= 4, let (done, failed, message) = await group.next() { outcomes[done] = (failed, message) }
      group.addTask {
        let (failed, message) = await assignOne(skill, to: bot, assigned: assigned, client: client)
        return (index, failed, message)
      }
    }
    for await (done, failed, message) in group { outcomes[done] = (failed, message) }
  }
  return (outcomes.contains { $0?.failed == true }, outcomes.compactMap { $0?.message })
}

private func assignOne(
  _ skill: SelectableSkill, to bot: BulkSkillBot, assigned: Bool, client: APIClient
) async -> (Bool, BulkSkillMessage?) {
  let label = "\(skill.label) → \(bot.name)"
  do {
    let skipped = try await client.assignSharedSkill(skill.id, agentID: bot.id, assigned: assigned)
    guard skipped else { return (false, nil) }
    return (false, BulkSkillMessage(
      id: "skipped:\(skill.id):\(bot.id)", text: "Skipped \(label): already in the requested state."))
  } catch {
    return (true, BulkSkillMessage(
      id: "failed:\(skill.id):\(bot.id)", text: "Failed \(label): \(friendlyError(error))"))
  }
}

public enum SkillSelectionState: Sendable {
  case none, some, all
}

/// The Skills page's selection and the bulk action running on it. Skills a bulk delete picked
/// leave the page at once and come back selected if the server refuses them.
@MainActor @Observable
public final class SkillBulkBoard {
  public private(set) var selected: Set<String> = []
  public private(set) var isRunning = false
  /// How many skills the running action covers, since a delete hides them.
  public private(set) var runningCount = 0
  public private(set) var hidden: Set<String> = []
  public private(set) var report: [BulkSkillMessage] = []
  private var generation = 0

  public init() {}

  public func reset() {
    generation += 1
    selected = []
    isRunning = false
    runningCount = 0
    hidden = []
    report = []
  }

  public func change(_ ids: [String], isOn: Bool) {
    if isOn { selected.formUnion(ids) } else { selected.subtract(ids) }
  }

  public func clear() { selected = [] }

  public func state(of ids: [String]) -> SkillSelectionState {
    let count = ids.filter(selected.contains).count
    return count == 0 ? .none : count == ids.count ? .all : .some
  }

  func run(
    _ action: BulkSkillAction, picked: [SelectableSkill], bots: [BulkSkillBot], client: APIClient,
    deleted: @escaping @MainActor (Set<String>) -> Void, finished: @escaping @MainActor () -> Void
  ) {
    guard !isRunning, !picked.isEmpty else { return }
    let version = generation
    isRunning = true
    runningCount = picked.count
    report = []
    if action == .delete { hidden = Set(picked.map(\.id)) }
    Task {
      let result = await runBulkSkillAction(action, picked: picked, bots: bots, client: client)
      guard generation == version else { return }
      if action == .delete { deleted(hidden.subtracting(result.failed)) }
      hidden = []
      isRunning = false
      runningCount = 0
      selected = result.failed
      report = result.messages
      finished()
    }
  }
}
