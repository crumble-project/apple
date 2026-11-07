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
public enum CodingJobItem: Identifiable, Hashable, Sendable {
  case task(id: String, text: String)
  case reply(id: String, text: String)
  case tool(Tool)

  public struct Tool: Hashable, Sendable {
    public var id: String
    public var name: String
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

  /// Turns job history, oldest first, into items: tool results fold into the call they answer.
  public static func items(from messages: [Message]) -> [CodingJobItem] {
    var items: [CodingJobItem] = []
    var open: [String: Int] = [:]
    for message in messages {
      switch message.role {
      case "user":
        if !message.text.isEmpty { items.append(.task(id: message.id, text: message.text)) }
      case "assistant":
        appendAssistantItems(of: message, to: &items, open: &open)
      case "toolResult":
        appendResult(of: message, to: &items, open: open)
      default:
        break
      }
    }
    return items
  }

  private static func appendAssistantItems(
    of message: Message, to items: inout [CodingJobItem], open: inout [String: Int]
  ) {
    guard case .array(let blocks)? = message.blocks else {
      if !message.text.isEmpty { items.append(.reply(id: message.id, text: message.text)) }
      return
    }
    for (index, block) in blocks.enumerated() {
      let id = "\(message.id):\(index)"
      switch block["type"]?.stringValue {
      case "text":
        let text = (block["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { items.append(.reply(id: id, text: text)) }
      case "toolCall":
        let arguments = block["arguments"]
        let subject = arguments?["command"]?.stringValue ?? arguments?["path"]?.stringValue ?? ""
        if let callID = block["id"]?.stringValue, !callID.isEmpty { open[callID] = items.count }
        items.append(
          .tool(
            Tool(
              id: id, name: block["name"]?.stringValue ?? "", subject: subject, output: "",
              isError: false, finished: false)))
      default:
        break
      }
    }
  }

  private static func appendResult(of message: Message, to items: inout [CodingJobItem], open: [String: Int]) {
    let failed = message.isError == true
    if let callID = message.toolCallId, let index = open[callID], case .tool(var tool) = items[index] {
      tool.output = message.text
      tool.isError = failed
      tool.finished = true
      items[index] = .tool(tool)
    } else {
      items.append(
        .tool(
          Tool(
            id: message.id, name: message.toolName ?? "", subject: "", output: message.text, isError: failed,
            finished: true)))
    }
  }
}
