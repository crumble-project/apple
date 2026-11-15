import Foundation

/// What a bot is doing during a turn, as the server's chat snapshot reports it.
public enum Working: String, Codable, Sendable {
  case idle, thinking, writing, searching, remembering, tinkering, struggling, failed

  public var label: String {
    switch self {
    case .idle, .failed: "Working"
    case .thinking: "Thinking"
    case .writing: "Writing"
    case .searching: "Searching"
    case .remembering: "Remembering"
    case .tinkering: "Using tools"
    case .struggling: "Retrying"
    }
  }
}
