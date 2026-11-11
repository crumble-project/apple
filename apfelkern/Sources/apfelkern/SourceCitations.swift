import Foundation

/// A page a bot searched or read in the turn that wrote a message.
public struct MessageSource: Codable, Hashable, Sendable {
  public var url: String
  public var title: String

  public init(url: String, title: String) {
    self.url = url
    self.title = title
  }
}
