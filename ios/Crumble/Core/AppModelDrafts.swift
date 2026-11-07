import Foundation

struct SkillDraft: Identifiable, Sendable {
  let id = UUID()
  var skillID: String
  var agentID: String?
  var name = ""
  var instructions = ""
  /// The bots that use a shared skill.
  var usedBy: Set<String> = []
}
