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

/// One readable step of a coding job's history.
public enum CodingJobItem: Identifiable, Hashable, Sendable, Decodable {
  case task(id: String, text: String)
  case reply(id: String, text: String)
  case tool(Tool)

  public struct Tool: Hashable, Sendable {
    public var id: String
    public var name: String
    public var label: String = ""
    public var icon: String = "tool"
    /// The command a `bash` call ran, or the path a file call touched.
    public var subject: String
    public var output: String
    public var isError: Bool
    public var finished: Bool

    /// The whole output as an expanded step shows it.
    public var shownOutput: String {
      output.trimmingCharacters(in: .newlines).nilIfEmpty ?? "No output."
    }
  }

  public var id: String {
    switch self {
    case .task(let id, _), .reply(let id, _): id
    case .tool(let tool): tool.id
    }
  }

  private enum CodingKeys: String, CodingKey { case kind, id, text, tool, label, icon, subject, result }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(String.self, forKey: .id)
    switch try values.decode(String.self, forKey: .kind) {
    case "task": self = .task(id: id, text: try values.decode(String.self, forKey: .text))
    case "reply": self = .reply(id: id, text: try values.decode(String.self, forKey: .text))
    case "step":
      let result = try values.decodeIfPresent(Message.self, forKey: .result)
      self = .tool(Tool(id: id, name: try values.decode(String.self, forKey: .tool),
        label: try values.decode(String.self, forKey: .label), icon: try values.decode(String.self, forKey: .icon),
        subject: try values.decodeIfPresent(String.self, forKey: .subject) ?? "",
        output: result?.text ?? "", isError: result?.isError == true, finished: result != nil))
    default: throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown job item")
    }
  }
}
