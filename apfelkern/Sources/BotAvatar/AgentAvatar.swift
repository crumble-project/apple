import apfelkern
import SwiftUI

extension BotAvatarView {
  public init(agent: Agent, size: CGFloat, state: BotState = .idle, live: Bool = false, reaction: Int = 0) {
    self.init(seed: agentAvatarSeed(agent), size: size, state: state, live: live, reaction: reaction)
  }
}
