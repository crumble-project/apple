import apfelkern
import OpenBotAvatar
import OpenBotAvatarUI
import Testing

@testable import BotAvatar

struct BotAvatarTests {
  @Test func onlyWorkingBotsThink() {
    #expect(BotState.working.mood == .thinking)
    #expect(BotState.idle.mood == .idle)
    #expect(BotState.sleeping.mood == .idle)
  }

  @Test func bodyColorFallsBackForAnInvalidColor() {
    var avatar = BotAvatarDefinition.default(for: "bot")
    avatar.color = "orange"
    #expect(avatar.bodyColor == .init(AvatarColor.defaultBody))
  }
}
