import apfelkern
import OpenBotAvatar
import OpenBotAvatarUI
import SwiftUI

public enum BotState: Sendable {
  case idle, working, sleeping

  var mood: AvatarMood { self == .working ? .thinking : .idle }
}

extension BotAvatarDefinition {
  /// The body color also serves as the bot's accent.
  public var bodyColor: Color { Color(AvatarColor(hex: color) ?? .defaultBody) }
  var eyesColor: Color { Color(AvatarColor(hex: eyeColor) ?? .defaultEyes) }
}

/// A bot's avatar at a fixed size, so nothing moves while the definition builds off the main thread
/// on first use. Only live avatars animate: thumbnails draw once, and sleeping bots hold still.
public struct BotAvatarView: View {
  let avatar: BotAvatarDefinition
  let size: CGFloat
  var state: BotState = .idle
  var live = false

  public init(avatar: BotAvatarDefinition, size: CGFloat, state: BotState = .idle, live: Bool = false) {
    self.avatar = avatar
    self.size = size
    self.state = state
    self.live = live
  }

  public init(agent: Agent, size: CGFloat, state: BotState = .idle, live: Bool = false) {
    self.init(avatar: agent.avatar, size: size, state: state, live: live)
  }

  public var body: some View {
    AvatarView(
      avatar.definition, color: avatar.bodyColor, eyeColor: avatar.eyesColor, mood: state.mood,
      still: !live || state == .sleeping, label: "")
      .frame(width: size, height: size)
      .opacity(state == .sleeping ? 0.45 : 1)
  }
}
