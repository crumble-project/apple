import Foundation

public enum AutomationStatus: String, CaseIterable, Sendable {
  case active, paused, completed

  public var label: String { rawValue.capitalized }
}

/// The list's status filter.
public enum AutomationFilter: Hashable, CaseIterable, Sendable {
  case all, active, paused, completed

  public var label: String {
    switch self {
    case .all: "All"
    case .active: AutomationStatus.active.label
    case .paused: AutomationStatus.paused.label
    case .completed: AutomationStatus.completed.label
    }
  }

  func includes(_ schedule: Schedule) -> Bool {
    switch self {
    case .all: true
    case .active: schedule.status == .active
    case .paused: schedule.status == .paused
    case .completed: schedule.status == .completed
    }
  }
}

extension Schedule {
  /// A one-time automation that has run and won't run again.
  public var isFinished: Bool { cron?.nilIfEmpty == nil && eventSourceId == nil && nextRunAt == nil }

  public var status: AutomationStatus {
    if isFinished { return .completed }
    return enabled ? .active : .paused
  }

  fileprivate var nextRun: Date { nextRunAt.flatMap(automationRunDate) ?? .distantFuture }
}

/// Soonest first within each status. A finished one-time prompt has done its work and leaves the list;
/// a finished script stays, since its runs are read here.
public func listedAutomations(_ schedules: [Schedule]) -> [Schedule] {
  let rank: [AutomationStatus: Int] = [.active: 0, .paused: 1, .completed: 2]
  return schedules.filter { $0.kind == .script || !$0.isFinished }.sorted { first, second in
    let (one, other) = (rank[first.status] ?? 0, rank[second.status] ?? 0)
    if one != other { return one < other }
    if first.nextRun != second.nextRun { return first.nextRun < second.nextRun }
    return first.name.localizedCompare(second.name) == .orderedAscending
  }
}

/// When an automation next runs, close by in words; a dash when paused or finished.
public func nextRunLabel(_ schedule: Schedule, now: Date = .now) -> String {
  guard schedule.enabled, let next = schedule.nextRunAt.flatMap(automationRunDate) else { return "—" }
  let seconds = next.timeIntervalSince(now)
  guard seconds < 86_400 else {
    return next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
  }
  let minutes = Int((seconds / 60).rounded())
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .full
  return formatter.localizedString(
    from: minutes < 60
      ? DateComponents(minute: max(minutes, 0)) : DateComponents(hour: Int((Double(minutes) / 60).rounded())))
}

public enum ScriptRunStatus: String, Codable, Hashable, Sendable {
  case running, succeeded, failed, interrupted
  case timedOut = "timed_out"

  public var label: String {
    switch self {
    case .running: "Running"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .timedOut: "Timed out"
    case .interrupted: "Interrupted"
    }
  }
}

/// One run of a script automation, with the tail of its output.
public struct ScriptRun: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var scheduleId: String
  public var agentId: String
  public var command: String
  public var status: ScriptRunStatus
  public var exitCode: Int?
  public var output: String
  /// Bytes dropped from the output tail.
  public var droppedBytes: Int
  public var error: String?
  public var startedAt: String
  public var finishedAt: String?

  public init(
    id: String, scheduleId: String, agentId: String, command: String, status: ScriptRunStatus,
    exitCode: Int? = nil, output: String = "", droppedBytes: Int = 0, error: String? = nil,
    startedAt: String, finishedAt: String? = nil
  ) {
    self.id = id
    self.scheduleId = scheduleId
    self.agentId = agentId
    self.command = command
    self.status = status
    self.exitCode = exitCode
    self.output = output
    self.droppedBytes = droppedBytes
    self.error = error
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  public func duration(now: Date = .now) -> String {
    let end = finishedAt.flatMap(automationRunDate) ?? now
    let seconds = automationRunDate(startedAt).map { max(0, end.timeIntervalSince($0)) } ?? 0
    return String(format: "%.1f s", seconds)
  }
}

/// A row of the run history: a chat run that opens the bot's chat, or a script run that opens its output.
public struct AutomationRun: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var agentId: String
  public var started: Date
  public var statusLabel: String
  public var failed: Bool
  public var running: Bool
  public var error: String?
  public var script: ScriptRun?

  static let shown = 100
  static let deletedTitle = "Deleted automation"

  init(execution: Execution, title: String?) {
    id = execution.id
    self.title = title ?? Self.deletedTitle
    agentId = execution.agentId ?? ""
    started = execution.createdAt.flatMap(automationRunDate) ?? .distantPast
    let status = execution.status ?? ""
    statusLabel = ["pending": "Queued", "running": "Running", "done": "Done", "failed": "Failed",
                   "cancelled": "Cancelled"][status] ?? status
    failed = status == "failed"
    running = status == "running" || status == "pending"
    error = execution.error
  }

  init(script run: ScriptRun, title: String?) {
    id = run.id
    self.title = title ?? Self.deletedTitle
    agentId = run.agentId
    started = automationRunDate(run.startedAt) ?? .distantPast
    statusLabel = run.status.label
    running = run.status == .running
    failed = run.status != .succeeded && !running
    error = run.error
    script = run
  }
}

/// Chat runs and script runs together, newest first.
func automationRuns(
  schedules: [Schedule], executions: [Execution], scriptRuns: [ScriptRun]
) -> [AutomationRun] {
  let names = Dictionary(schedules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  let chats = executions.compactMap { execution in
    execution.scheduleId.map { AutomationRun(execution: execution, title: names[$0]) }
  }
  let scripts = scriptRuns.map { AutomationRun(script: $0, title: names[$0.scheduleId]) }
  return Array((chats + scripts).sorted { $0.started > $1.started }.prefix(AutomationRun.shown))
}
