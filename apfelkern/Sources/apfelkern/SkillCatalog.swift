import Foundation

/// Whose skills the Skills page shows.
public enum SkillScope: Hashable, Sendable {
  case all, shared, defaults
  case bot(String)
}

public struct SkillScopeOption: Identifiable, Hashable, Sendable {
  public var scope: SkillScope
  public var label: String
  /// Nil while a bot's skills couldn't be read.
  public var count: Int?

  public var id: SkillScope { scope }

  public var title: String { count.map { "\(label) (\($0))" } ?? label }
}

/// A skill the Skills page can select, shared or a bot's own.
public struct SelectableSkill: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var instructions: String
  public var agentID: String?
  public var ownerName: String
  public var isInstalled: Bool

  public init(
    id: String, name: String, instructions: String = "", agentID: String? = nil, ownerName: String = "Shared",
    isInstalled: Bool = false
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.agentID = agentID
    self.ownerName = ownerName
    self.isInstalled = isInstalled
  }

  public var label: String { "\(name) (\(ownerName))" }
}

/// One bot's skills on the Skills page.
public struct SkillOwner: Identifiable, Sendable {
  public var agent: Agent
  public var skills: [BotSkill]
  /// False until its list loads, or when it can't.
  public var isAvailable: Bool

  public var id: String { agent.id }
}

/// What the Skills page shows for a search and an owner.
@MainActor
public struct SkillCatalog {
  public let scope: SkillScope
  public let needle: String
  public let shared: [SharedSkill]
  public let defaults: [SharedSkill]
  public let owners: [SkillOwner]

  public init(skills: [SharedSkill], agents: [Agent], botSkills: BotSkillBoard, hidden: Set<String> = [],
              scope: SkillScope, search: String) {
    self.scope = scope
    needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let visible = skills.filter { !hidden.contains($0.id) }
    shared = visible.filter { !$0.isDefault }
    defaults = visible.filter(\.isDefault)
    owners = agents.map { agent in
      SkillOwner(
        agent: agent, skills: botSkills.skills(agentID: agent.id).filter { !hidden.contains($0.id) },
        isAvailable: botSkills.isLoaded(agentID: agent.id) && botSkills.readError(agentID: agent.id) == nil)
    }
  }

  public func matches(_ name: String, _ instructions: String) -> Bool {
    needle.isEmpty || name.lowercased().contains(needle) || instructions.lowercased().contains(needle)
  }

  private func matches(_ skill: SharedSkill) -> Bool { matches(skill.name, skill.instructions) }

  public var visibleShared: [SharedSkill] { shows(.shared) ? shared.filter(matches) : [] }

  public var visibleDefaults: [SharedSkill] { shows(.defaults) ? defaults.filter(matches) : [] }

  public var showsShared: Bool { shows(.shared) }

  public var showsDefaults: Bool { shows(.defaults) }

  /// Every bot's section stays while it loads or fails, since that is where its retry lives.
  public var visibleOwners: [SkillOwner] {
    switch scope {
    case .all: owners.filter { owner in !owner.isAvailable || owner.skills.contains(where: matches) }
    case .bot(let id): owners.filter { $0.id == id }
    case .shared, .defaults: []
    }
  }

  public func matches(_ skill: BotSkill) -> Bool { matches(skill.name, skill.instructions) }

  private func shows(_ section: SkillScope) -> Bool { scope == .all || scope == section }

  public var options: [SkillScopeOption] {
    let own = owners.reduce(0) { $0 + $1.skills.count }
    let everyLoaded = owners.allSatisfy(\.isAvailable)
    return [
      SkillScopeOption(scope: .all, label: "All", count: everyLoaded ? shared.count + own + defaults.count : nil),
      SkillScopeOption(scope: .shared, label: "Shared", count: shared.count)
    ] + owners.map {
      SkillScopeOption(scope: .bot($0.id), label: $0.agent.name, count: $0.isAvailable ? $0.skills.count : nil)
    } + [SkillScopeOption(scope: .defaults, label: "Default", count: defaults.count)]
  }

  /// Every shared and bot skill, including ones the filter hides. A skill the server hasn't
  /// confirmed yet can't be selected.
  public var selectable: [SelectableSkill] {
    let skills = shared.map {
      SelectableSkill(id: $0.id, name: $0.name, instructions: $0.instructions, isInstalled: $0.isInstalled)
    } + owners.flatMap { owner in
      owner.skills.map {
        SelectableSkill(
          id: $0.id, name: $0.name, instructions: $0.instructions, agentID: owner.id, ownerName: owner.agent.name)
      }
    }
    return skills.filter { !$0.id.hasPrefix("pending-") }
  }

  public func picked(_ selected: Set<String>) -> [SelectableSkill] {
    selectable.filter { selected.contains($0.id) }
  }

  public var visibleIDs: [String] {
    selectable.filter { skill in
      let inScope = switch scope {
      case .all: true
      case .shared: skill.agentID == nil
      case .bot(let id): skill.agentID == id
      case .defaults: false
      }
      return inScope && matches(skill.name, skill.instructions)
    }.map(\.id)
  }

  public var installed: Bool { shared.contains(where: \.isInstalled) }
}

/// Which bots use a shared skill, and the changes that take them to `selected`.
extension [Agent] {
  public func using(skill skillID: String) -> Set<String> {
    Set(filter { $0.sharedSkills?.contains(skillID) == true }.map(\.id))
  }

  func assignmentChanges(skill skillID: String, selected: Set<String>) -> [(agentID: String, enabled: Bool)] {
    let using = using(skill: skillID)
    return compactMap { agent in
      using.contains(agent.id) == selected.contains(agent.id)
        ? nil : (agent.id, selected.contains(agent.id))
    }
  }
}
