import Foundation

public func agentAvatarSeed(_ agent: Agent) -> String {
  let avatar = agent.avatar ?? ""
  for prefix in ["bot:", "critters:"] where avatar.hasPrefix(prefix) {
    let seed = avatar.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    if !seed.isEmpty { return seed }
  }
  return agent.id.trimmingCharacters(in: .whitespaces).isEmpty ? "crumble" : agent.id
}
