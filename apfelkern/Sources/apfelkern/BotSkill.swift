import Foundation

/// A bot's own skill. Documents and usage stay on the server, which keeps them across edits.
public struct BotSkill: Identifiable, Hashable, Sendable {
  public var id: String
  public var agentID: String
  public var name: String
  public var instructions: String
  /// Bots and reviews can't change a pinned skill, and cleanup leaves it alone.
  public var pinned: Bool

  public init(id: String, agentID: String, name: String, instructions: String, pinned: Bool = false) {
    self.id = id
    self.agentID = agentID
    self.name = name
    self.instructions = instructions
    self.pinned = pinned
  }

  init(wire: Components.Schemas.SkillPackage, agentID: String) {
    self.init(
      id: wire.id, agentID: agentID, name: wire.name, instructions: wire.instructions, pinned: wire.pinned)
  }

  /// The first line of the instructions, without Markdown heading marks.
  public var glimpse: String { skillGlimpse(instructions) }
}

func skillGlimpse(_ instructions: String) -> String {
  instructions.split(whereSeparator: \.isNewline)
    .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
    .first { !$0.isEmpty } ?? "No instructions."
}
