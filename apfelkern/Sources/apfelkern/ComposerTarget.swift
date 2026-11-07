/// What a composer writes to: a bot chat or a group chat.
public struct ComposerTarget {
  public var placeholder: String
  public var enabled: Bool
  /// Bots that `@` completes.
  public var mentionable: [Agent]
  /// The bot whose reasoning the composer sets; nil in a group chat.
  public var bot: Agent?
  public var running: Bool
  public var stopHelp: String
  public var send: @MainActor () -> Void
  public var stop: @MainActor () -> Void

  public init(
    placeholder: String, enabled: Bool, mentionable: [Agent], bot: Agent? = nil, running: Bool, stopHelp: String,
    send: @escaping @MainActor () -> Void, stop: @escaping @MainActor () -> Void
  ) {
    self.placeholder = placeholder
    self.enabled = enabled
    self.mentionable = mentionable
    self.bot = bot
    self.running = running
    self.stopHelp = stopHelp
    self.send = send
    self.stop = stop
  }
}
