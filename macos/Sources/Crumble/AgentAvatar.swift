import apfelkern
import BotAvatar
import SwiftUI

extension BotAvatarView {
    init(agent: Agent, size: CGFloat, state: BotState = .idle, live: Bool = false) {
        self.init(seed: agentAvatarSeed(agent), size: size, state: state, live: live)
    }
}
