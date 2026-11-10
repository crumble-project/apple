import Foundation

/// The server's web search providers.
public enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case mixed, exa

  public var id: Self { self }

  public var name: String {
    switch self {
    case .mixed: "Mixed"
    case .exa: "Exa"
    }
  }
}
