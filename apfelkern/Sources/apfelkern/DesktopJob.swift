import Foundation
import OpenAPIRuntime

/// What a job's own model requests spent, summed over every model it used.
public struct JobUsage: Codable, Hashable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  /// Input tokens read from the provider's prompt cache, billed at a lower rate.
  public var cachedTokens: Int
  /// In US dollars, as the server's model catalog prices it.
  public var cost: Double

  public init(inputTokens: Int, outputTokens: Int, cachedTokens: Int, cost: Double) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.cost = cost
  }

  /// Sums the server's usage document (`models`, keyed by provider and model); nil when it has none.
  init?(document: OpenAPIValueContainer?) {
    guard let document, let usage = try? JSONValue(wire: document),
      case .object(let models)? = usage["models"], !models.isEmpty
    else { return nil }
    var total = JobUsage(inputTokens: 0, outputTokens: 0, cachedTokens: 0, cost: 0)
    for model in models.values {
      total.inputTokens += Int(model["input"]?.numberValue ?? 0)
      total.outputTokens += Int(model["output"]?.numberValue ?? 0)
      total.cachedTokens += Int(model["cacheRead"]?.numberValue ?? 0)
      total.cost += model["cost"]?["total"]?.numberValue ?? 0
    }
    // Summing binary fractions leaves noise below a millionth of a cent.
    total.cost = (total.cost * 1e8).rounded() / 1e8
    self = total
  }
}

/// A named piece of desktop work a bot runs on its bot desktop.
public struct DesktopJob: Codable, Identifiable, Hashable, Sendable {
  public static let toolName = "desktop"
  public static let originKind = "desktop"

  public var name: String
  public var conversationId: String
  public var status: String
  public var usage: JobUsage?

  public var id: String { name }
  public var isWorking: Bool { status == "working" }

  public init(name: String, conversationId: String, status: String, usage: JobUsage? = nil) {
    self.name = name
    self.conversationId = conversationId
    self.status = status
    self.usage = usage
  }

  /// The job a successful `desktop` tool result names; nil for status listings and other messages.
  public init?(message: Message) {
    guard message.role == "toolResult", message.toolName == Self.toolName, message.isError != true,
      let details = message.toolDetails,
      let name = details["name"]?.stringValue, !name.isEmpty
    else { return nil }
    self.init(
      name: name, conversationId: details["conversationId"]?.stringValue ?? "",
      status: details["status"]?.stringValue ?? "idle")
  }
}

extension APIClient {
  public func desktopJobs(_ agentID: String) async throws -> [DesktopJob] {
    try await invoke {
      try await $0.listDesktopJobs(.init(path: .init(id: agentID))).ok.body.json.jobs.map {
        DesktopJob(
          name: $0.name, conversationId: $0.conversationId, status: $0.status.rawValue,
          usage: JobUsage(document: $0.usage))
      }
    }
  }

  public func desktopJobHistory(_ agentID: String, name: String, before: String, limit: Int)
    async throws -> ChatHistoryResponse {
    try await invoke {
      try ChatHistoryResponse(wire: await $0.getDesktopJobHistory(.init(
        path: .init(id: agentID, name: name),
        query: .init(limit: limit > 0 ? limit : nil, before: before.nilIfEmpty)
      )).ok.body.json)
    }
  }
}
