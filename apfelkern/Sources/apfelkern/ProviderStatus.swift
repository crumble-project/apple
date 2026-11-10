import Foundation

public struct ProviderStatus: Codable, Hashable, Sendable {
  public var provider: String
  public var name: String?
  /// Saved or ambient credentials make the provider usable.
  public var configured: Bool

  public init(provider: String, name: String? = nil, configured: Bool) {
    self.provider = provider
    self.name = name
    self.configured = configured
  }
}
