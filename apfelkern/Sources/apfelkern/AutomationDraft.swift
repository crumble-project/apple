import Foundation

/// The server's limits on an automation.
public enum AutomationLimits {
  public static let name = 200
  public static let prompt = 32000
  public static let command = 8000
  public static let cron = 100
  public static let maxTimeoutSeconds = 3600
  public static let defaultTimeoutSeconds = 600
}

/// A script automation needs a bot with coding on a server that runs jobs.
public func canRunScripts(_ agent: Agent?, capabilities: ServerCapabilities?) -> Bool {
  capabilities?.coding == true && agent?.tools?.contains(CodingJob.toolName) == true
}

/// What the editor holds. Every field of a saved automation round-trips, so a script or event
/// automation keeps its command and trigger when only its name changes.
public struct AutomationDraft: Identifiable, Sendable {
  public let id = UUID()
  public var scheduleID: String
  public var agentID: String
  public var name = ""
  public var enabled = true
  public var kind = ScheduleKind.prompt
  public var prompt = ""
  public var command = ""
  public var timeoutSeconds = String(AutomationLimits.defaultTimeoutSeconds)
  public var notify = true
  public var repeats = false
  public var cron = "0 9 * * *"
  /// The builder can show this cron, but the owner chose to write it by hand.
  public var customCron = false
  public var runDate = Calendar.current.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(3600)) ?? .now
  public var timezone = TimeZone.current.identifier
  public var onEvent = false
  public var eventSourceId = ""

  public init(agentID: String) {
    scheduleID = ""
    self.agentID = agentID
  }

  /// Nil when the server's run time can't be read.
  public init?(schedule: Schedule) {
    scheduleID = schedule.id
    agentID = schedule.agentId
    name = schedule.name
    enabled = schedule.enabled
    kind = schedule.kind
    prompt = schedule.prompt
    command = schedule.command ?? ""
    timeoutSeconds = String(schedule.timeoutSeconds)
    notify = schedule.notify
    repeats = schedule.cron?.isEmpty == false
    if let cron = schedule.cron?.nilIfEmpty { self.cron = cron }
    customCron = repeats && Recurrence(cron: cron) == nil
    if let runAt = schedule.runAt {
      guard let date = automationRunDate(runAt) else { return nil }
      runDate = date
    }
    timezone = schedule.timezone ?? timezone
    onEvent = schedule.eventSourceId != nil
    eventSourceId = schedule.eventSourceId ?? ""
  }

  public var isNew: Bool { scheduleID.isEmpty }

  public var when: AutomationWhen {
    get {
      guard repeats else { return .once }
      guard !customCron, let recurrence else { return .custom }
      return AutomationWhen(rawValue: recurrence.kind.rawValue) ?? .custom
    }
    set {
      customCron = newValue == .custom
      repeats = newValue != .once
      if let kind = newValue.recurrenceKind {
        cron = (recurrence ?? Recurrence(kind: kind)).switched(to: kind).cron
      }
    }
  }

  /// The builder's view of the cron; nil when it can't show it.
  public var recurrence: Recurrence? {
    get { Recurrence(cron: cron) }
    set { if let newValue { cron = newValue.cron } }
  }

  public var zone: TimeZone? { TimeZone(identifier: trimmed(timezone)) }

  private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Why the draft can't be saved; nil when it can.
  public var problem: String? {
    if agentID.isEmpty { return "Choose which bot runs this automation." }
    if kind == .prompt, trimmed(name).isEmpty || trimmed(prompt).isEmpty {
      return "Automation name and prompt are required."
    }
    if kind == .script {
      if trimmed(name).isEmpty || trimmed(command).isEmpty { return "Automation name and command are required." }
      guard let timeout = Int(trimmed(timeoutSeconds)), (1...AutomationLimits.maxTimeoutSeconds).contains(timeout)
      else { return "Timeout must be between 1 and \(AutomationLimits.maxTimeoutSeconds) seconds." }
    }
    if onEvent { return eventSourceId.isEmpty ? "Choose an event source." : nil }
    if repeats, trimmed(cron).isEmpty { return "Choose either a recurring cron or a one-time run time." }
    return zone == nil ? "Choose a valid time zone." : nil
  }

  /// Exactly one is set, as the server requires.
  private struct Trigger {
    var cron: String?
    var runAt: String?
    var eventSourceId: String?
  }

  private var trigger: Trigger {
    if onEvent { return Trigger(eventSourceId: eventSourceId) }
    return repeats ? Trigger(cron: trimmed(cron)) : Trigger(runAt: runDate.ISO8601Format())
  }

  private var timeout: Int {
    kind == .script ? Int(trimmed(timeoutSeconds)) ?? AutomationLimits.defaultTimeoutSeconds
      : AutomationLimits.defaultTimeoutSeconds
  }

  /// The whole automation, with its unused trigger fields as explicit nulls so an edit can move between them.
  public var payload: [String: JSONValue] {
    let optional = { (value: String?) in value.map(JSONValue.string) ?? .null }
    return [
      "agentId": .string(agentID), "name": .string(trimmed(name)), "kind": .string(kind.rawValue),
      "prompt": .string(kind == .prompt ? trimmed(prompt) : ""),
      "command": optional(kind == .script ? command : nil),
      "timeoutSeconds": .number(Double(timeout)), "notify": .bool(notify),
      "timezone": .string(trimmed(timezone)), "enabled": .bool(enabled),
      "cron": optional(trigger.cron), "runAt": optional(trigger.runAt),
      "eventSourceId": optional(trigger.eventSourceId)
    ]
  }

  /// The row to show until the server answers.
  public func provisional(id: String, replacing old: Schedule?, now: Date = .now) -> Schedule {
    let trigger = trigger
    let cronRun = trigger.cron.flatMap { cron in
      zone.flatMap { CronExpression(cron)?.next(after: now, in: $0) }
    }
    return Schedule(
      id: id, agentId: agentID, name: trimmed(name), cron: trigger.cron,
      prompt: kind == .prompt ? trimmed(prompt) : "", kind: kind, command: kind == .script ? command : nil,
      timeoutSeconds: timeout, notify: notify, timezone: trimmed(timezone), runAt: trigger.runAt,
      eventSourceId: trigger.eventSourceId, enabled: enabled,
      nextRunAt: trigger.runAt ?? cronRun?.ISO8601Format(), createdByAgentId: old?.createdByAgentId)
  }

  /// The line under the When section; nil for an event automation, which has no next run.
  public func preview(now: Date = .now) -> AutomationPreview? {
    guard !onEvent else { return nil }
    guard let zone else { return AutomationPreview(text: "Choose a valid time zone.", isProblem: true) }
    let zoneName = trimmed(timezone)
    guard repeats else {
      return runDate < now
        ? AutomationPreview(text: "This time has passed.", isProblem: true)
        : AutomationPreview(text: "Runs \(humanRun(runDate, zone: zone, now: now)) (\(zoneName))", isProblem: false)
    }
    guard let expression = CronExpression(cron) else {
      return AutomationPreview(text: "The server checks this schedule when you save.", isProblem: false)
    }
    guard let run = expression.next(after: now, in: zone) else {
      return AutomationPreview(text: "This schedule never runs.", isProblem: true)
    }
    return AutomationPreview(text: "Next run \(humanRun(run, zone: zone, now: now)) (\(zoneName))", isProblem: false)
  }
}

public struct AutomationPreview: Equatable, Sendable {
  public var text: String
  public var isProblem: Bool
}
