import Foundation

struct SkillDraft: Identifiable, Sendable {
    let id = UUID()
    var skillID: String
    var agentID: String?
    var personal = false
    var name = ""
    var instructions = ""
}
