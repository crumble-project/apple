import Foundation
import Observation

/// What the owner has written for a job's question, kept across scrolling and failed sends.
public struct JobAnswer: Hashable, Sendable {
  public var text = ""
  public var picked: Set<String> = []
  /// The reply on its way to the server.
  public var sent: String?
  public var error = ""

  public var sending: Bool { sent != nil }

  public init() {}

  /// A multiple-choice answer lists the picked options, then anything written.
  public func reply(to question: JobQuestion) -> String {
    let chosen = (question.options ?? []).filter(picked.contains).joined(separator: ", ")
    let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return [chosen, written].filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

/// The selected bot's jobs, the job panel, and answers to job questions. Results that return after
/// the selection or connection changed are dropped.
@MainActor @Observable
public final class JobBoard {
  public private(set) var jobs: [String: Job] = [:]
  public var history: JobHistory?
  /// Keyed by question ID.
  public var answers: [String: JobAnswer] = [:]
  private var listed: Set<JobKind> = []
  /// Questions answered here; a listing already in flight may still name them.
  private var answered: Set<String> = []
  private var activity = 0
  private var agentID = ""
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    agentID = ""
    jobs = [:]
    history = nil
    answers = [:]
    listed = []
    answered = []
    activity = 0
  }

  /// Reopening the same bot's chat keeps the open job and unsent answers, and refreshes the jobs.
  public func select(_ agentID: String) {
    activity = 0
    guard agentID != self.agentID else { return }
    reset()
    self.agentID = agentID
  }

  // MARK: Jobs

  /// A job's status changes when it starts and when its report reaches the chat, and a job's
  /// question arrives as an event, so a change in those messages is the cue to ask the server again.
  public func refreshIfChanged(messages: [Message], agentID: String, client: APIClient) {
    let related = messages.compactMap(Self.kind)
    guard related.count != activity else { return }
    activity = related.count
    for kind in Set(related) { refresh(kind, agentID: agentID, client: client) }
  }

  private static func kind(of message: Message) -> JobKind? {
    if message.jobQuestion != nil { return .coding }
    return Job(message: message)?.kind ?? JobKind.allCases.first { $0.originKind == message.origin?.kind }
  }

  public func refresh(_ kind: JobKind, agentID: String, client: APIClient) {
    let version = scope
    Task {
      guard let loaded = try? await client.jobs(kind, agentID: agentID), scope == version else { return }
      let previous = jobs
      jobs = jobs.filter { $0.value.kind != kind }
      for var job in loaded {
        if let question = job.question, answered.contains(question.id) { job.question = nil }
        jobs[job.id] = job
      }
      listed.insert(kind)
      if let open = history, open.agentID == agentID, open.kind == kind,
        previous[Job.id(kind, open.name)]?.status != jobs[Job.id(kind, open.name)]?.status {
        loadHistory(client: client)
      }
    }
  }

  /// The job as its card should show it: the server's current status wins over the status the tool
  /// result recorded when it ran.
  public func job(_ recorded: Job) -> Job {
    jobs[recorded.id] ?? recorded
  }

  // MARK: Polling

  private static let workingDelay = Duration.seconds(3)
  private static let idleDelay = Duration.seconds(15)
  private static let questionDelay = Duration.seconds(5)

  private var openJobWorks: Bool {
    history.flatMap { jobs[Job.id($0.kind, $0.name)]?.isWorking } ?? false
  }
  private var questionOpen: Bool { jobs.values.contains { $0.question != nil } }

  /// How often to ask again: the chat only hears of a job's start and report, which misses its own
  /// progress and a question its reporter answered. Nil when nothing on screen depends on it.
  public func pollDelay(messages: [Message]) -> Duration? {
    var delays: [Duration] = []
    if history != nil { delays.append(openJobWorks ? Self.workingDelay : Self.idleDelay) }
    if questionOpen || (!listed.contains(.coding) && messages.contains { $0.jobQuestion != nil }) {
      delays.append(Self.questionDelay)
    }
    return delays.min()
  }

  /// Runs until cancelled; give it a new delay by restarting it.
  public func watch(every delay: Duration, agentID: String, client: APIClient) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      if openJobWorks { loadHistory(client: client) }
      var kinds: Set<JobKind> = history.map { [$0.kind] } ?? [.coding]
      if questionOpen { kinds.insert(.coding) }
      for kind in kinds { refresh(kind, agentID: agentID, client: client) }
    }
  }

  // MARK: History

  public func open(_ kind: JobKind, _ name: String, agentID: String, client: APIClient) {
    history = JobHistory(agentID: agentID, kind: kind, name: name)
    loadHistory(client: client)
  }

  public func close() {
    history = nil
  }

  public func loadHistory(client: APIClient) {
    guard let open = history else { return }
    Task {
      do {
        let page = try await client.jobHistory(
          open.kind, agentID: open.agentID, name: open.name, before: "", limit: 100)
        // Changed as a copy: reading the observed property while writing it is an exclusivity violation.
        guard var current = history, current.id == open.id else { return }
        current.messages = mergeMessages(current.messages, page.messages ?? [])
        if !current.loaded {
          current.hasMore = page.hasMore ?? false
          current.oldestEntryID = page.oldestEntryId ?? ""
        }
        current.loaded = true
        current.error = ""
        history = current
      } catch {
        guard history?.id == open.id else { return }
        history?.error = friendlyError(error)
      }
    }
  }

  public func loadOlderHistory(client: APIClient) {
    guard let open = history, open.hasMore, !open.loadingOlder, !open.oldestEntryID.isEmpty else { return }
    history?.loadingOlder = true
    Task {
      do {
        let page = try await client.jobHistory(
          open.kind, agentID: open.agentID, name: open.name, before: open.oldestEntryID, limit: 100)
        guard var current = history, current.id == open.id else { return }
        current.messages = mergeMessages(current.messages, page.messages ?? [])
        current.hasMore = page.hasMore ?? false
        current.oldestEntryID = page.oldestEntryId ?? ""
        current.loadingOlder = false
        history = current
      } catch {
        guard history?.id == open.id else { return }
        history?.loadingOlder = false
        history?.error = friendlyError(error)
      }
    }
  }

  public func downloadTranscript(client: APIClient) {
    guard let open = history, !open.downloading else { return }
    history?.downloading = true
    history?.transcriptError = ""
    Task {
      do {
        let messages = try await client.fullJobHistory(open.kind, agentID: open.agentID, name: open.name)
        guard history?.id == open.id else { return }
        history?.downloading = false
        history?.transcript = JobTranscript(kind: open.kind, name: open.name, messages: messages)
      } catch {
        guard history?.id == open.id else { return }
        history?.downloading = false
        history?.transcriptError = friendlyError(error)
      }
    }
  }

  // MARK: Questions

  public func toggle(_ option: String, for questionID: String) {
    if answers[questionID, default: JobAnswer()].picked.remove(option) == nil {
      answers[questionID]?.picked.insert(option)
    }
  }

  /// The open question, while the job waits on it.
  public func waitingQuestion(_ id: String) -> JobQuestion? {
    jobs.values.lazy.compactMap(\.question).first { $0.id == id }
  }

  /// Whether the listing has answered if a question is still open.
  public var codingJobsListed: Bool { listed.contains(.coding) }

  /// Sends the answer, which resumes the job. The job's state belongs to the server, so the box shows
  /// a pending state, and a failure leaves what the owner wrote in place for another try.
  public func answer(
    _ question: JobQuestion, job: String, reply: String, agentID: String, client: APIClient
  ) {
    guard !reply.isEmpty, answers[question.id]?.sending != true else { return }
    let version = scope
    answers[question.id, default: JobAnswer()].sent = reply
    answers[question.id]?.error = ""
    Task {
      do {
        try await client.answerCodingJob(agentID, name: job, questionID: question.id, text: reply)
        guard scope == version else { return }
        answers[question.id] = nil
        answered.insert(question.id)
        jobs[Job.id(.coding, job)]?.question = nil
      } catch {
        guard scope == version else { return }
        answers[question.id]?.sent = nil
        answers[question.id]?.error = friendlyError(error)
      }
      // A 409 means the job moved on; the listing retires the question.
      refresh(.coding, agentID: agentID, client: client)
    }
  }
}
