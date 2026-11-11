import Foundation

/// What a bot is doing during a turn, read from the transcript as the web's working status does.
public enum Working: String, Sendable {
  case idle, thinking, writing, searching, remembering, tinkering, struggling, failed

  public init(snapshot: ChatSnapshot?, messages: [Message]) {
    self = snapshot?.working.flatMap(Working.init(rawValue:)) ?? .idle
  }

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
