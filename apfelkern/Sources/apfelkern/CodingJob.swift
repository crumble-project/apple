import Foundation

/// What the server can do beyond the basics, so clients show only controls that work.
public struct ServerCapabilities: Codable, Hashable, Sendable {
  public var coding: Bool
  /// Whether bots can get a bot desktop and run desktop jobs.
  public var desktop: Bool

  public init(coding: Bool = false, desktop: Bool = false) {
    self.coding = coding
    self.desktop = desktop
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    coding = try container.decodeIfPresent(Bool.self, forKey: .coding) ?? false
    desktop = try container.decodeIfPresent(Bool.self, forKey: .desktop) ?? false
  }
}

/// A named piece of coding work a bot runs in its workspace.
public struct CodingJob: Codable, Identifiable, Hashable, Sendable {
  public static let toolName = "coding"
  public static let originKind = "coding"

  public var name: String
  public var conversationId: String
  public var status: String
  public var usage: JobUsage?
  public var model: DesktopModel?
  /// What the job asked the owner and waits on.
  public var question: JobQuestion?

  public var id: String { name }
  public var isWorking: Bool { status == "working" }

  public init(
    name: String, conversationId: String, status: String, usage: JobUsage? = nil,
    model: DesktopModel? = nil, question: JobQuestion? = nil
  ) {
    self.name = name
    self.conversationId = conversationId
    self.status = status
    self.usage = usage
    self.model = model
    self.question = question
  }

  /// The job a successful `coding` tool result names; nil for status listings and other messages.
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

public typealias CodingJobsResponse = Components.Schemas.CodingJobs

/// A question a coding job waits on until its reporter or the owner answers.
public struct JobQuestion: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var text: String
  /// Answers the owner can pick; any other text is an answer too.
  public var options: [String]?
  /// Whether several options can be picked; the answer lists each.
  public var multiple: Bool?

  public var allowsMultiple: Bool { multiple == true }

  public init(id: String, text: String, options: [String]? = nil, multiple: Bool? = nil) {
    self.id = id
    self.text = text
    self.options = options
    self.multiple = multiple
  }
}

/// On a `job-question` event: the job that asked. Whether it still waits is the job's listing.
public struct JobQuestionEvent: Codable, Hashable, Sendable {
  public static let messageKind = "job-question"

  public var id: String
  public var kind: String
  public var job: String

  public init(id: String, kind: String, job: String) {
    self.id = id
    self.kind = kind
    self.job = job
  }
}

/// One readable item of a job's history: its task, a reply, or a tool step with its result once it has one.
/// The server reads them from the transcript, attaching a result even when it landed on a newer page.
public typealias JobHistoryItem = Components.Schemas.JobHistoryItem
public typealias JobStepItem = Components.Schemas.JobStepItem

extension Components.Schemas.JobHistoryItem: Identifiable {
  public var id: String {
    switch self {
    case .task(let task): task.id
    case .reply(let reply): reply.id
    case .step(let step): step.id
    }
  }

  /// A step still waiting on its tool's result.
  var isUnfinishedStep: Bool {
    if case .step(let step) = self { step.result == nil } else { false }
  }
}

extension Components.Schemas.JobStepItem {
  public var finished: Bool { result != nil }
  public var isError: Bool { result?.isError == true }

  /// The whole output as an expanded step shows it.
  public var shownOutput: String {
    (result?.content ?? "").trimmingCharacters(in: .newlines).nilIfEmpty ?? "No output."
  }
}

/// Keeps items loaded earlier and those the newest page has scrolled past; the newest page replaces the rest.
public func mergeJobItems(_ existing: [JobHistoryItem], _ newest: [JobHistoryItem]) -> [JobHistoryItem] {
  guard let first = newest.first?.id else { return existing }
  return existing.prefix { $0.id != first } + newest
}
