import Foundation

/// Unsent text by conversation, as the web keeps it per chat. `defaults` keeps it across launches.
public struct ComposerDrafts {
  private static let storageKey = "crumble.composerDrafts"
  private var texts: [String: String]
  private let defaults: UserDefaults?

  public init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    texts = defaults?.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
  }

  /// `conversation` is a bot's ID or a group's delivery key; empty means no chat is open.
  public subscript(conversation: String) -> String? {
    get { texts[conversation] }
    set {
      guard !conversation.isEmpty else { return }
      texts[conversation] = newValue?.nilIfEmpty
      defaults?.set(texts, forKey: Self.storageKey)
    }
  }

  public mutating func removeAll() {
    texts = [:]
    defaults?.removeObject(forKey: Self.storageKey)
  }
}
