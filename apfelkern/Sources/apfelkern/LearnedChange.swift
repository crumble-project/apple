import Foundation

public enum ChangeActor: String, Hashable, Sendable {
  case owner, bot, review, curator
}

public enum ChangeTarget: String, Hashable, Sendable {
  case skill, memory
}

public enum ChangeAction: String, Hashable, Sendable {
  case create, update, delete, revert

  fileprivate var verb: String {
    switch self {
    case .create: "added"
    case .update: "changed"
    case .delete: "deleted"
    case .revert: "reverted"
    }
  }
}

/// A skill or memory as it stood on one side of a change.
public enum LearnedState: Hashable, Sendable {
  case skill(SkillPackage)
  case memory(Memory)

  init?(skill: Components.Schemas.SkillPackage?, memory: Components.Schemas.Memory?) {
    if let skill {
      self = .skill(SkillPackage(wire: skill))
    } else if let memory {
      self = .memory(Memory(wire: memory))
    } else {
      return nil
    }
  }

  fileprivate var title: String {
    switch self {
    case .skill(let skill): skill.name
    case .memory(let memory): lines(memory.content).first ?? ""
    }
  }

  fileprivate var diffLines: [String] {
    switch self {
    case .skill(let skill): skill.diffLines
    case .memory(let memory): lines(memory.content)
    }
  }
}

/// A change to a skill or memory, with the state on each side. Reverting records a change of its own.
public struct LearnedChange: Identifiable, Hashable, Sendable {
  public var id: String
  public var agentID: String?
  public var actor: ChangeActor
  public var target: ChangeTarget
  public var targetID: String
  public var action: ChangeAction
  public var before: LearnedState?
  public var after: LearnedState?
  public var createdAt: String

  public init(
    id: String, agentID: String? = nil, actor: ChangeActor, target: ChangeTarget, targetID: String,
    action: ChangeAction, before: LearnedState? = nil, after: LearnedState? = nil, createdAt: String
  ) {
    self.id = id
    self.agentID = agentID
    self.actor = actor
    self.target = target
    self.targetID = targetID
    self.action = action
    self.before = before
    self.after = after
    self.createdAt = createdAt
  }

  public func summary(botName: String?) -> String {
    let what = target == .skill ? "a skill" : agentID == nil ? "a shared memory" : "a memory"
    return "\(actorLabel(botName)) \(action.verb) \(what)"
  }

  public var title: String { (after ?? before)?.title ?? targetID }

  public var diff: [SkillDiffLine] {
    skillDiff(before: before?.diffLines ?? [], after: after?.diffLines ?? [])
  }

  public var revertTitle: String { "Revert this change?" }

  public var revertNote: String {
    let name = target.rawValue
    let outcome = before == nil
      ? "The \(name) is deleted again."
      : "The \(name) goes back to how it was before this change. Anything changed since is replaced."
    return outcome + " The revert is recorded, so you can undo it too."
  }

  public var createdDate: Date? { automationRunDate(createdAt) }

  private func actorLabel(_ botName: String?) -> String {
    switch actor {
    case .owner: "You"
    case .bot: botName ?? "A bot"
    case .review: botName.map { "\($0)'s review" } ?? "A review"
    case .curator: "The curator"
    }
  }
}

/// One calendar day of a list, in the list's order.
public struct ActivityDay<Item: Sendable>: Identifiable, Sendable {
  public var id: String
  public var label: String
  public var items: [Item]
}

/// Groups by calendar day in the order days first appear, so a list stays newest first.
public func activityDays<Item: Sendable>(
  _ items: [Item], date: (Item) -> Date?, now: Date = .now, calendar: Calendar = .current
) -> [ActivityDay<Item>] {
  var days: [ActivityDay<Item>] = []
  for item in items {
    let when = date(item)
    let id = when.map { calendar.startOfDay(for: $0).timeIntervalSince1970.description } ?? "undated"
    if let index = days.firstIndex(where: { $0.id == id }) {
      days[index].items.append(item)
    } else {
      days.append(ActivityDay(id: id, label: dayLabel(when, now: now, calendar: calendar), items: [item]))
    }
  }
  return days
}

private func dayLabel(_ date: Date?, now: Date, calendar: Calendar) -> String {
  guard let date else { return "Earlier" }
  let days = calendar.dateComponents(
    [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
  if days == 0 { return "Today" }
  if days == 1 { return "Yesterday" }
  var format = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    .weekday(.wide).day().month(.wide)
  if !calendar.isDate(date, equalTo: now, toGranularity: .year) { format = format.year() }
  return date.formatted(format)
}

extension LearnedChange {
  init(wire: Components.Schemas.LearnedChange) throws {
    guard let actor = ChangeActor(rawValue: wire.actor.rawValue),
      let target = ChangeTarget(rawValue: wire.target.rawValue),
      let action = ChangeAction(rawValue: wire.action.rawValue) else {
      throw DecodingError.valueNotFound(
        LearnedChange.self, .init(codingPath: [], debugDescription: "Unknown change kind"))
    }
    self.init(
      id: wire.id, agentID: wire.agentId, actor: actor, target: target, targetID: wire.targetId, action: action,
      before: LearnedState(skill: wire.before?.value1, memory: wire.before?.value2),
      after: LearnedState(skill: wire.after?.value1, memory: wire.after?.value2),
      createdAt: wire.createdAt)
  }
}
