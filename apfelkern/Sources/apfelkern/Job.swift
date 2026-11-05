import Foundation

/// The kinds of background job a bot runs: coding jobs in its workspace, desktop jobs on its bot desktop.
public enum JobKind: String, CaseIterable, Hashable, Sendable {
  case coding, desktop

  /// Lowercase, for sentences: "coding job".
  public var noun: String {
    switch self {
    case .coding: "coding job"
    case .desktop: "desktop job"
    }
  }

  public var icon: String {
    switch self {
    case .coding: "hammer.fill"
    case .desktop: "display"
    }
  }

  /// The message origin of the job's reports in the bot chat.
  public var originKind: String {
    switch self {
    case .coding: CodingJob.originKind
    case .desktop: DesktopJob.originKind
    }
  }

  /// A job's report behind its card; the bot relays what matters.
  public static func isReport(_ message: Message) -> Bool {
    allCases.contains { $0.originKind == message.origin?.kind }
  }
}

/// A job as the chat shows it, of either kind.
public struct Job: Hashable, Identifiable, Sendable {
  public var kind: JobKind
  public var name: String
  public var status: String
  public var usage: JobUsage?
  /// The model it runs with; nil when it uses the server's default.
  public var model: String?
  /// The question it waits on; only coding jobs ask.
  public var question: JobQuestion?

  public var id: String { Job.id(kind, name) }
  public var isWorking: Bool { status == "working" }

  public static func id(_ kind: JobKind, _ name: String) -> String { kind.rawValue + "/" + name }

  public init(
    kind: JobKind, name: String, status: String, usage: JobUsage? = nil, model: String? = nil,
    question: JobQuestion? = nil
  ) {
    self.kind = kind
    self.name = name
    self.status = status
    self.usage = usage
    self.model = model
    self.question = question
  }

  /// The job a successful `coding` or `desktop` tool result names.
  public init?(message: Message) {
    if let job = CodingJob(message: message) {
      self.init(kind: .coding, name: job.name, status: job.status)
    } else if let job = DesktopJob(message: message) {
      self.init(kind: .desktop, name: job.name, status: job.status)
    } else {
      return nil
    }
  }

  /// The job's model and what it spent, for its panel's title.
  public func summary(locale: Locale = .current) -> String {
    [model, usage.map { usageLine($0, locale: locale) }].compactMap(\.self).joined(separator: " · ")
  }
}

/// A job's history as its panel shows it, oldest first.
public struct JobHistory: Identifiable, Sendable {
  public let agentID: String
  public let kind: JobKind
  public let name: String
  public var messages: [Message] = []
  public var hasMore = false
  public var oldestEntryID = ""
  public var loaded = false
  public var loadingOlder = false
  public var error = ""
  public var downloading = false
  public var transcriptError = ""
  /// The finished transcript, waiting for the owner to pick where it goes.
  public var transcript: JobTranscript?

  public var id: String { agentID + "/" + Job.id(kind, name) }

  public init(agentID: String, kind: JobKind, name: String) {
    self.agentID = agentID
    self.kind = kind
    self.name = name
  }
}

/// Tokens and cost of a job's own model requests, as one short line: "1,000 in · 500 out · $0.0020".
/// Subscription providers report zero cost, which says nothing, so the line leaves it out.
public func usageLine(_ usage: JobUsage, locale: Locale = .current) -> String {
  let count = IntegerFormatStyle<Int>.number.locale(locale)
  let tokens = "\(usage.inputTokens.formatted(count)) in · \(usage.outputTokens.formatted(count)) out"
  guard usage.cost > 0 else { return tokens }
  let cost = usage.cost.formatted(.currency(code: "USD").precision(.fractionLength(4)).locale(locale))
  return "\(tokens) · \(cost)"
}

extension APIClient {
  /// Jobs of one kind, oldest first.
  public func jobs(_ kind: JobKind, agentID: String) async throws -> [Job] {
    switch kind {
    case .coding:
      try await codingJobs(agentID).map {
        Job(
          kind: .coding, name: $0.name, status: $0.status, usage: $0.usage, model: $0.model?.model,
          question: $0.question)
      }
    case .desktop:
      try await desktopJobs(agentID).map {
        Job(kind: .desktop, name: $0.name, status: $0.status, usage: $0.usage, model: $0.model?.model)
      }
    }
  }

  public func jobHistory(_ kind: JobKind, agentID: String, name: String, before: String, limit: Int)
    async throws -> ChatHistoryResponse {
    switch kind {
    case .coding: try await codingJobHistory(agentID, name: name, before: before, limit: limit)
    case .desktop: try await desktopJobHistory(agentID, name: name, before: before, limit: limit)
    }
  }

  /// Every page of a job's history, oldest message first.
  public func fullJobHistory(_ kind: JobKind, agentID: String, name: String) async throws -> [Message] {
    var pages: [[Message]] = []
    var before = ""
    repeat {
      let page = try await jobHistory(kind, agentID: agentID, name: name, before: before, limit: 200)
      pages.append(page.messages ?? [])
      before = page.hasMore == true ? page.oldestEntryId ?? "" : ""
    } while !before.isEmpty
    return pages.reversed().flatMap(\.self)
  }
}
