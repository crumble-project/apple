import Foundation

/// What a bot is doing during a turn, read from the transcript as the web's working status does.
public enum Working: String, Sendable {
  case idle, thinking, writing, searching, remembering, tinkering, struggling, failed

  private static let searchTools: Set<String> = [
    "web_search", "web_extract", "history_search", "history_read"
  ]
  private static let memoryTool = "memory"

  public init(snapshot: ChatSnapshot?, messages: [Message]) {
    switch snapshot?.status {
    case "failed": self = .failed
    case "running":
      self = Self.turn(partial: snapshot?.partial, last: messages.last { $0.deliveryState == .confirmed })
    default: self = .idle
    }
  }

  private static func turn(partial: String?, last: Message?) -> Working {
    if partial?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return .writing }
    guard let last else { return .thinking }
    if last.role == "toolResult", last.isError == true { return .struggling }
    guard last.role == "assistant", case .array(let blocks)? = last.blocks else { return .thinking }
    let tools = blocks.filter { $0["type"]?.stringValue == "toolCall" }
      .map { $0["name"]?.stringValue ?? "" }
    if tools.isEmpty { return .thinking }
    if tools.contains(where: searchTools.contains) { return .searching }
    return tools.contains(memoryTool) ? .remembering : .tinkering
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
