import Foundation
import OpenBotAvatar

/// A bot's avatar: portable geometry with its body and eye colors, as `#rgb` or `#rrggbb`.
public struct BotAvatarDefinition: Codable, Hashable, Sendable {
  public var definition: AvatarDefinition
  public var color: String
  public var eyeColor: String

  public init(definition: AvatarDefinition, color: String, eyeColor: String) {
    self.definition = definition
    self.color = color
    self.eyeColor = eyeColor
  }

  /// The starter the server gives a bot without an avatar; the same hash picks the same one.
  public static func `default`(for botID: String) -> Self {
    let hash = botID.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value }
    let starters = AvatarCatalog.examples
    return Self(
      definition: starters[Int(hash % UInt32(starters.count))],
      color: AvatarColor.defaultBody.hex, eyeColor: AvatarColor.defaultEyes.hex)
  }

  public static func generationPrompt(_ description: String) -> String {
    let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(avatarGenerationPrompt)\n\n## User description\n\n\(description)\n"
  }

  /// This avatar with imported geometry; colors are separate from the portable definition.
  public func importing(json: String) -> Result<Self, AvatarValidationError> {
    AvatarDefinition.validate(json: json).map {
      Self(definition: $0, color: color, eyeColor: eyeColor)
    }
  }

  /// This avatar in other colors, or nil unless both are `#rgb` or `#rrggbb`.
  public func recolored(color: String, eyeColor: String) -> Self? {
    let hex = /#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})/
    guard color.wholeMatch(of: hex) != nil, eyeColor.wholeMatch(of: hex) != nil else { return nil }
    return Self(definition: definition, color: color, eyeColor: eyeColor)
  }
}

extension BotAvatarDefinition {
  /// Decoding doesn't validate and an invalid definition renders empty, so one falls back to the
  /// bot's starter geometry.
  init(wire: Components.Schemas.BotAvatarDefinition, botID: String) {
    let geometry = wire.definition
    let definition = AvatarDefinition(
      version: Int(geometry.version), id: geometry.id, name: geometry.name,
      body: AvatarBody(path: geometry.body.path),
      eyes: AvatarEyes(
        x: geometry.eyes.x, y: geometry.eyes.y, spacing: geometry.eyes.spacing, scale: geometry.eyes.scale))
    self.init(
      definition: (try? definition.validated().get()) ?? Self.default(for: botID).definition,
      color: wire.color, eyeColor: wire.eyeColor)
  }
}
