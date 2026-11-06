import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func wire(
  _ id: String, name: String = "Automation", prompt: String = "Say hi", kind: String = "prompt",
  command: String? = nil, timeout: Int = 600, notify: Bool = true, cron: String? = nil, runAt: String? = nil,
  source: String? = nil, enabled: Bool = true, next: String? = nil
) -> String {
  let text = { (value: String?) in value.map { #""\#($0)""# } ?? "null" }
  return #"""
    {"id":"\#(id)","agentId":"a1","name":"\#(name)","prompt":"\#(prompt)","kind":"\#(kind)",
     "command":\#(text(command)),"timeoutSeconds":\#(timeout),"notify":\#(notify),"cron":\#(text(cron)),
     "timezone":"Europe/Berlin","runAt":\#(text(runAt)),"eventSourceId":\#(text(source)),
     "enabled":\#(enabled),"nextRunAt":\#(text(next)),"createdAt":"2026-11-05T10:00:00.000Z",
     "createdByAgentId":null}
    """#
}

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

private let script = wire(
  "s1", name: "Backup", prompt: "", kind: "script", command: "./backup.sh", timeout: 90, notify: false,
  cron: "0 3 * * *", next: "2026-11-07T02:00:00.000Z")
private let event = wire("s1", name: "Issues", prompt: "Triage it", source: "src1")

/// Opens the one listed automation and saves it unchanged, returning what was sent.
@MainActor
private func savedUnchanged(_ schedule: String) async throws -> JSONValue {
  let sent = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if request.httpMethod == "PATCH" {
      try sent.withLock { $0.append(try requestJSON(request)) }
      return json(schedule)
    }
    return json("[\(schedule)]")
  }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.edit(board.schedules[0])
    board.saveDraft(client: client)
    #expect(board.saveError.isEmpty)
    #expect(board.draft == nil)
    try await wait { !board.isPending("s1") && !sent.withLock { $0.isEmpty } }
  })
  let first = sent.withLock { $0.first }
  return try #require(first)
}

// Before this board, editing a script failed on its blank prompt, and an event automation was
// saved with a run time an hour away and no event source.
@MainActor
@Test func aScriptAutomationSavedUnchangedKeepsItsCommand() async throws {
  guard case .object(let body) = try await savedUnchanged(script) else { throw CancellationError() }
  #expect(body["kind"] == .string("script"))
  #expect(body["command"] == .string("./backup.sh"))
  #expect(body["timeoutSeconds"] == .number(90))
  #expect(body["notify"] == .bool(false))
  #expect(body["cron"] == .string("0 3 * * *"))
  #expect(body["runAt"] == .null)
  #expect(body["eventSourceId"] == .null)
}

@MainActor
@Test func anEventAutomationSavedUnchangedKeepsItsSource() async throws {
  guard case .object(let body) = try await savedUnchanged(event) else { throw CancellationError() }
  #expect(body["eventSourceId"] == .string("src1"))
  #expect(body["cron"] == .null)
  #expect(body["runAt"] == .null)
  #expect(body["prompt"] == .string("Triage it"))
}

@MainActor
@Test func pausingSendsOnlyEnabledSoAScriptCannotChange() async throws {
  let sent = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if request.httpMethod == "PATCH" {
      try sent.withLock { $0.append(try requestJSON(request)) }
      return json(script)
    }
    return json("[\(script)]")
  }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.setEnabled(board.schedules[0], false, client: client)
    #expect(board.schedules[0].enabled == false)
    try await wait { !sent.withLock { $0.isEmpty } }
  })
  let first = sent.withLock { $0.first }
  #expect(first == .object(["enabled": .bool(false)]))
}

@MainActor
@Test func aRefusedPauseFlipsBackAndSaysWhy() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "PATCH" ? json(#"{"error":"busy"}"#, status: 500) : json("[\(script)]")
  }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.setEnabled(board.schedules[0], false, client: client)
    #expect(board.schedules[0].enabled == false)
    try await wait { board.errors["s1"] != nil }
    #expect(board.errors["s1"]?.contains("busy") == true)
    #expect(board.schedules[0].enabled == true)
  })
}

@MainActor
@Test func aReadDuringASaveKeepsTheLocalChangeUntilTheServerAnswers() async throws {
  let renamed = wire("s1", name: "New name", cron: "0 9 * * *")
  try await withClient(handler: { request in
    request.httpMethod == "PATCH"
      ? json(renamed, delay: 0.1) : json("[\(wire("s1", name: "Old", cron: "0 9 * * *"))]")
  }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.edit(board.schedules[0])
    board.draft?.name = "New name"
    board.saveDraft(client: client)
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.schedules[0].name == "New name")
    #expect(board.isPending("s1"))
    try await wait { !board.isPending("s1") }
  })
}

@MainActor
@Test func aFailedCreateRemovesItsRowAndReopensTheDraft() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? json(#"{"error":"busy"}"#, status: 500, delay: 0.02) : json("[]")
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.name = "Morning"
    board.draft?.prompt = "Say hi"
    board.draft?.runDate = .now.addingTimeInterval(600)
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(board.schedules.map(\.name) == ["Morning"])
    #expect(board.shown.map(\.name) == ["Morning"])
    try await wait { board.draft != nil }
    #expect(board.schedules.isEmpty)
    #expect(board.draft?.name == "Morning")
    #expect(board.saveError.contains("busy"))
  })
}

@MainActor
@Test func aFailedAutomationSaveWaitsForTheOpenSheetToClose() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? json(#"{"error":"bad cron"}"#, status: 400, delay: 0.02) : json("[]")
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.name = "Morning"
    board.draft?.prompt = "A long prompt"
    board.draft?.runDate = .now.addingTimeInterval(600)
    board.saveDraft(client: client)
    board.openNew(agentID: "a1")
    board.draft?.name = "Typing"
    try await wait { board.schedules.isEmpty }
    #expect(board.draft?.name == "Typing")
    #expect(board.saveError.isEmpty)
    board.closeDraft()
    #expect(board.draft?.prompt == "A long prompt")
    #expect(board.saveError.contains("bad cron"))
    #expect(board.errors.isEmpty)
  })
}

@MainActor
@Test func aCreateOnlySendsOneTrigger() async throws {
  let sent = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      try sent.withLock { $0.append(try requestJSON(request)) }
      return json(wire("new", source: "src1"), status: 201)
    }
    return json("[]")
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.name = "Issues"
    board.draft?.prompt = "Triage"
    board.draft?.onEvent = true
    board.saveDraft(client: client)
    #expect(board.saveError == "Choose an event source.")
    board.draft?.eventSourceId = "src1"
    board.saveDraft(client: client)
    try await wait { !sent.withLock { $0.isEmpty } }
  })
  let first = sent.withLock { $0.first }
  guard case .object(let body)? = first else { throw CancellationError() }
  #expect(body["eventSourceId"] == .string("src1"))
  #expect(body["cron"] == .null)
  #expect(body["runAt"] == .null)
  #expect(body["command"] == .null)
}

@MainActor
@Test func aLateAnswerFromAnOldConnectionIsDropped() async throws {
  try await withClient(handler: { _ in json("[\(script)]", delay: 0.05) }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!board.isLoaded)
  })
}

@MainActor
@Test func runsJoinChatAndScriptHistoriesNewestFirst() async throws {
  let execution = #"""
    {"id":"e1","agentId":"a1","conversationId":"c","scheduleId":"s2","submissionId":null,"requestId":"r",
     "prompt":"p","status":"done","error":null,"createdAt":"2026-11-05T10:00:00.000Z",
     "updatedAt":"2026-11-05T10:00:00.000Z"}
    """#
  let turn = execution.replacingOccurrences(of: #""scheduleId":"s2""#, with: #""scheduleId":null"#)
    .replacingOccurrences(of: #""id":"e1""#, with: #""id":"e2""#)
  let run = #"""
    {"id":"r1","scheduleId":"s1","agentId":"a1","command":"./backup.sh","status":"timed_out","exitCode":null,
     "output":"tail","droppedBytes":12,"error":"Timed out","startedAt":"2026-11-05T11:00:00.000Z",
     "finishedAt":"2026-11-05T11:00:02.500Z"}
    """#
  try await withClient(handler: { request in
    let path = request.url?.path ?? ""
    if path.hasSuffix("/executions") { return json("[\(execution),\(turn)]") }
    if path.hasSuffix("/s1/runs") { return json("[\(run)]") }
    return json("[\(script),\(wire("s2", name: "Chat", cron: "0 9 * * *"))]")
  }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client, includingRuns: true)
    try await wait { board.runsLoaded || board.runsError != nil }
    #expect(board.runsError == nil)
    #expect(board.runs.count == 2)
    guard board.runs.count == 2 else { return }
    #expect(board.runs.map(\.id) == ["r1", "e1"])
    #expect(board.runs[0].statusLabel == "Timed out")
    #expect(board.runs[0].failed)
    #expect(board.runs[0].script?.duration() == "2.5 s")
    #expect(board.runs[1].title == "Chat")
    #expect(!board.runs[1].failed)
  })
}

@Test func theListHidesFinishedPromptsAndKeepsFinishedScripts() {
  let once = Schedule(id: "1", agentId: "a", name: "Done", prompt: "p", runAt: "2026-01-01T00:00:00Z", enabled: true)
  let finishedScript = Schedule(
    id: "2", agentId: "a", name: "Done script", prompt: "", kind: .script, command: "ls",
    runAt: "2026-01-01T00:00:00Z", enabled: true)
  let paused = Schedule(id: "3", agentId: "a", name: "Paused", cron: "0 9 * * *", prompt: "p", enabled: false)
  let soon = Schedule(
    id: "4", agentId: "a", name: "Soon", cron: "0 9 * * *", prompt: "p", enabled: true,
    nextRunAt: "2026-11-07T09:00:00Z")
  let later = Schedule(
    id: "5", agentId: "a", name: "Later", cron: "0 9 * * *", prompt: "p", enabled: true,
    nextRunAt: "2026-11-08T09:00:00Z")
  #expect(listedAutomations([finishedScript, once, paused, later, soon]).map(\.id) == ["4", "5", "3", "2"])
  #expect(finishedScript.status == .completed)
  #expect(paused.status == .paused)
  #expect(soon.status == .active)
  #expect(Schedule(id: "6", agentId: "a", name: "e", prompt: "p", eventSourceId: "s", enabled: true).status == .active)
}

@Test func nextRunReadsInWordsNearbyAndADashWhenPaused() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let schedule = { (seconds: TimeInterval, enabled: Bool) in
    Schedule(
      id: "s", agentId: "a", name: "n", cron: "* * * * *", prompt: "p", enabled: enabled,
      nextRunAt: now.addingTimeInterval(seconds).ISO8601Format())
  }
  #expect(nextRunLabel(schedule(300, true), now: now) == "in 5 minutes")
  #expect(nextRunLabel(schedule(7200, true), now: now) == "in 2 hours")
  #expect(nextRunLabel(schedule(300, false), now: now) == "—")
}

@Test func timingNamesEventSourcesAndPausedAutomations() {
  let event = Schedule(id: "s", agentId: "a", name: "n", prompt: "p", eventSourceId: "src", enabled: false)
  #expect(cadence(event) == "On event")
  #expect(cadence(event, sources: [EventSource(id: "src", name: "Issues")]) == "On event · Issues")
  #expect(automationTiming(event) == "Paused · On event")
}

@Test func theBuilderReadsAndWritesEachCronShape() throws {
  for cron in ["5 * * * *", "30 8 * * *", "0 9 * * 1-5", "0 9 * * 1,3", "15 7 12 * *"] {
    #expect(Recurrence(cron: cron)?.cron == cron)
  }
  #expect(Recurrence(cron: "*/5 * * * *") == nil)
  #expect(Recurrence(cron: "0 25 * * *") == nil)
  #expect(Recurrence(cron: "0 9 32 * *") == nil)
  #expect(Recurrence(cron: "0 9 * 1 *") == nil)
  #expect(Recurrence(cron: "0 9 * * 7")?.days == [0])
  #expect(Recurrence(cron: "0 9 1 * 1") == nil)
}

@Test func changingThePresetKeepsTheTime() {
  var draft = AutomationDraft(agentID: "a")
  draft.when = .daily
  draft.cron = "30 7 * * *"
  draft.when = .weekly
  #expect(draft.cron == "30 7 * * 1")
  draft.when = .monthly
  #expect(draft.cron == "30 7 1 * *")
  draft.when = .custom
  #expect(draft.when == .custom)
  #expect(draft.cron == "30 7 1 * *")
  draft.when = .once
  #expect(!draft.repeats)
  #expect(draft.when == .once)
}

@Test func theLastWeekdayStaysOn() {
  var recurrence = Recurrence(kind: .weekly, days: [1])
  recurrence.toggle(weekday: 1)
  #expect(recurrence.days == [1])
  recurrence.toggle(weekday: 3)
  recurrence.toggle(weekday: 1)
  #expect(recurrence.days == [3])
}

private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

private func instant(_ text: String) throws -> Date { try #require(automationRunDate(text)) }

@Test func cronFindsTheNextRunInItsZone() throws {
  let from = try instant("2026-11-06T10:30:00Z")
  #expect(CronExpression("0 9 * * *")?.next(after: from, in: berlin) == (try instant("2026-11-07T08:00:00Z")))
  #expect(CronExpression("*/15 * * * *")?.next(after: from, in: berlin) == (try instant("2026-11-06T10:45:00Z")))
  #expect(CronExpression("0 9 * * MON-FRI")?.next(after: from, in: berlin) == (try instant("2026-11-09T08:00:00Z")))
  #expect(CronExpression("0 0 1 JAN *")?.next(after: from, in: berlin) == (try instant("2026-12-31T23:00:00Z")))
  #expect(CronExpression("0 0 29 2 *")?.next(after: from, in: berlin) == (try instant("2028-02-28T23:00:00Z")))
  // Both set means either: the 15th, or the Monday that comes first.
  #expect(CronExpression("0 12 15 * 1")?.next(after: from, in: berlin) == (try instant("2026-11-09T11:00:00Z")))
}

@Test func cronSkipsATimeTheClockChangeRemoves() throws {
  let from = try instant("2027-03-27T12:00:00Z")
  #expect(CronExpression("30 2 * * *")?.next(after: from, in: berlin) == (try instant("2027-03-29T00:30:00Z")))
}

@Test func cronSaysWhenItCantTell() throws {
  #expect(CronExpression("0 0 L * *") == nil)
  #expect(CronExpression("@daily") == nil)
  #expect(CronExpression("not a cron") == nil)
  #expect(CronExpression("0 0 31 2 *")?.next(after: .now, in: berlin) == nil)
}

@Test func thePreviewSaysWhatTheScheduleWillDo() throws {
  let now = try instant("2026-11-06T10:30:00Z")
  var draft = AutomationDraft(agentID: "a")
  draft.timezone = "Europe/Berlin"
  draft.when = .daily
  #expect(draft.preview(now: now)?.text.hasPrefix("Next run tomorrow at ") == true)
  #expect(draft.preview(now: now)?.text.hasSuffix("(Europe/Berlin)") == true)
  draft.cron = "0 0 31 2 *"
  #expect(draft.preview(now: now) == AutomationPreview(text: "This schedule never runs.", isProblem: true))
  draft.cron = "0 0 L * *"
  #expect(draft.preview(now: now)?.isProblem == false)
  draft.when = .once
  draft.runDate = now.addingTimeInterval(-60)
  #expect(draft.preview(now: now) == AutomationPreview(text: "This time has passed.", isProblem: true))
  draft.onEvent = true
  #expect(draft.preview(now: now) == nil)
}

@Test func aDraftExplainsWhatStopsItSaving() {
  var draft = AutomationDraft(agentID: "a")
  #expect(draft.problem == "Automation name and prompt are required.")
  draft.name = "Backup"
  draft.kind = .script
  #expect(draft.problem == "Automation name and command are required.")
  draft.command = "./backup.sh"
  draft.timeoutSeconds = "0"
  #expect(draft.problem == "Timeout must be between 1 and 3600 seconds.")
  draft.timeoutSeconds = "90"
  #expect(draft.problem == nil)
  draft.timezone = "Not/AZone"
  #expect(draft.problem == "Choose a valid time zone.")
  draft.onEvent = true
  #expect(draft.problem == "Choose an event source.")
}

@Test func aPickerShowsASavedRunAtItsOwnInstant() throws {
  let schedule = Schedule(
    id: "s", agentId: "a", name: "n", prompt: "p", timezone: "Europe/Berlin", runAt: "2026-10-18T10:10:00Z",
    enabled: true)
  let draft = try #require(AutomationDraft(schedule: schedule))
  #expect(draft.runDate == (try instant("2026-10-18T10:10:00Z")))
  #expect(!draft.repeats)
  guard case .string(let runAt)? = draft.payload["runAt"] else { throw CancellationError() }
  #expect(automationRunDate(runAt) == draft.runDate)
  #expect(draft.payload["cron"] == .null)
  let unreadable = Schedule(id: "s", agentId: "a", name: "n", prompt: "p", runAt: "soon", enabled: true)
  #expect(AutomationDraft(schedule: unreadable) == nil)
}

@Test func onlyACodingBotOnACodingServerRunsScripts() {
  let coder = Agent(id: "a", name: "A", tools: [CodingJob.toolName])
  let plain = Agent(id: "b", name: "B", tools: [])
  let server = try? JSONDecoder().decode(ServerCapabilities.self, from: Data(#"{"coding":true}"#.utf8))
  #expect(canRunScripts(coder, capabilities: server))
  #expect(!canRunScripts(plain, capabilities: server))
  #expect(!canRunScripts(coder, capabilities: nil))
}

@MainActor
@Test func changingPagesKeepsADraftThatCameBack() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? json(#"{"error":"busy"}"#, status: 500) : json("[]")
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.name = "Morning"
    board.draft?.prompt = "Say hi"
    var failures = 0
    board.saveDraft(client: client) { failures += 1 }
    try await wait { board.draft != nil }
    #expect(failures == 1)
    board.closeUnchangedDraft()
    #expect(board.draft?.name == "Morning")
    board.closeDraft()
    board.openNew(agentID: "a1")
    board.closeUnchangedDraft()
    #expect(board.draft == nil)
  })
}

@MainActor
@Test func aBotsDetailsLeaveOutFinishedRuns() async throws {
  let list = [wire("s1", name: "Done", runAt: "2026-11-01T10:00:00.000Z"), wire("s2", name: "Daily", cron: "0 9 * * *")]
  try await withClient(handler: { _ in json("[" + list.joined(separator: ",") + "]") }, test: { client in
    let board = AutomationBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    #expect(board.schedules(on: "a1").map(\.name) == ["Daily"])
    #expect(board.schedules(on: "other").isEmpty)
  })
}
