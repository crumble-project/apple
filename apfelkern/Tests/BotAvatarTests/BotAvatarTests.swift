import apfelkern
import OpenBotAvatar
import OpenBotAvatarUI
import SwiftUI
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

struct BrandLogoTests {
  @Test func everyBundledLogoParsesToPathsInItsBox() throws {
    #expect(BrandArtwork.all.count == BrandLogoData.markup.count)
    for (key, artwork) in BrandArtwork.all {
      #expect(!artwork.layers.isEmpty, "\(key)")
      for layer in artwork.layers {
        #expect(!layer.path.isEmpty, "\(key)")
        let bounds = layer.path.boundingRect
        #expect(bounds.minX >= -2 && bounds.maxX <= artwork.box.width + 2, "\(key)")
        #expect(bounds.minY >= -2 && bounds.maxY <= artwork.box.height + 2, "\(key)")
        if case .gradient(let id) = layer.fill { #expect(artwork.gradients[id] != nil, "\(key)") }
      }
    }
  }

  @Test func logosCoverWhatTheWebBrands() {
    #expect(BrandArtwork.all[BrandLogo.provider(id: "anthropic", name: "Anthropic").key] != nil)
    #expect(BrandArtwork.all[BrandLogo.passwordManager(.onePassword).key] != nil)
    #expect(BrandArtwork.all[BrandLogo.passwordManager(.bitwarden).key] != nil)
    #expect(BrandArtwork.all[BrandLogo.gateway("discord").key] != nil)
    #expect(BrandArtwork.all[BrandLogo.provider(id: "radius", name: "Radius").key] == nil)
  }

  @Test func pathDataReadsCompactNumbersAndArcFlags() {
    #expect(svgPath("M1 2h3v4H1z").boundingRect == CGRect(x: 1, y: 2, width: 3, height: 4))
    let quarter = svgPath("M0 0a5 5 0 015 5").boundingRect
    #expect(abs(quarter.width - 5) < 0.01 && abs(quarter.height - 5) < 0.01)
    let rest = svgPath("M0 0l1-1.5.5.5").boundingRect
    #expect(abs(rest.width - 1.5) < 0.01 && abs(rest.height - 1.5) < 0.01)
    #expect(svgPath("M10 10").boundingRect.width == 0)
  }
}
