import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func wire(
  _ id: String, name: String = "Automation", prompt: String = "Say hi", kind: String = "prompt",
  command: String? = nil, timeout: Int = 600, notify: Bool = true, cron: String? = nil, runAt: String? = nil,
  source: String? = nil, enabled: Bool = true, next: String? = nil, described: String = ""
) -> String {
  let text = { (value: String?) in value.map { #""\#($0)""# } ?? "null" }
  return #"""
    {"id":"\#(id)","agentId":"a1","name":"\#(name)","prompt":"\#(prompt)","kind":"\#(kind)",
     "command":\#(text(command)),"timeoutSeconds":\#(timeout),"notify":\#(notify),"cron":\#(text(cron)),
     "timezone":"Europe/Berlin","runAt":\#(text(runAt)),"eventSourceId":\#(text(source)),
     "enabled":\#(enabled),"nextRunAt":\#(text(next)),"nextRunLabel":"soon",
     "description":"\#(described)","timing":"\#(described)",
     "createdAt":"2026-11-05T10:00:00.000Z",
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
  cron: "0 3 * * *", next: "2026-11-07T02:00:00.000Z", described: "Daily at 03:00")
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
    #expect(board.schedules[0].timing == "Paused · Daily at 03:00")
    #expect(board.schedules[0].nextRunLabel == "—")
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
    if request.url?.path.hasSuffix("/schedules/preview") == true {
      return json(#"{"description":"","text":"Choose an event source.","isProblem":true,"nextRunAt":null}"#)
    }
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
    await board.loadPreview(client: client, after: .zero)
    board.saveDraft(client: client)
    #expect(board.saveError == "Choose an event source.")
    #expect(sent.withLock { $0.isEmpty })
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
}

@Test func aPickerShowsASavedRunAtItsOwnInstant() throws {
  let schedule = Schedule(
    id: "s", agentId: "a", name: "n", prompt: "p", timezone: "Europe/Berlin", runAt: "2026-10-18T10:10:00Z",
    enabled: true)
  let draft = try #require(AutomationDraft(schedule: schedule))
  #expect(draft.runDate == (try #require(automationRunDate("2026-10-18T10:10:00Z"))))
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

private let preview = #"{"description":"At 09:00 (Europe/Berlin)","text":"Next run tomorrow at 09:00","#
  + #""isProblem":false,"nextRunAt":"2026-11-07T08:00:00.000Z"}"#

@MainActor
@Test func thePreviewAsksAboutTheCurrentTriggerAndDropsStaleAnswers() async throws {
  let asked = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    let body = try requestJSON(request)
    asked.withLock { $0.append(body) }
    return json(preview, delay: body["cron"] == .string("0 8 * * *") ? 0.05 : 0)
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.timezone = "Europe/Berlin"
    board.draft?.when = .daily
    board.draft?.cron = "0 8 * * *"
    let late = Task { await board.loadPreview(client: client, after: .zero) }
    try await wait { asked.withLock { $0.count } == 1 }
    board.draft?.cron = "0 9 * * *"
    await late.value
    #expect(board.draftPreview == nil)

    await board.loadPreview(client: client, after: .zero)
    #expect(board.draftPreview?.text == "Next run tomorrow at 09:00")
    #expect(asked.withLock { $0.last } == .object([
      "cron": .string("0 9 * * *"), "timezone": .string("Europe/Berlin")
    ]))
    board.draft?.when = .once
    #expect(board.draftPreview == nil)

    // An answer that lands after the connection changed is dropped too.
    board.draft?.when = .daily
    board.draft?.cron = "0 8 * * *"
    let dropped = Task { await board.loadPreview(client: client, after: .zero) }
    try await wait { asked.withLock { $0.count } == 3 }
    board.reset()
    await dropped.value
    #expect(board.draftPreview == nil)
  })
}

@MainActor
@Test func aPreviewWaitsForTheTriggerToSettle() async throws {
  let asked = Mutex(0)
  try await withClient(handler: { _ in
    asked.withLock { $0 += 1 }
    return json(preview)
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    let typing = Task { await board.loadPreview(client: client, after: .milliseconds(50)) }
    typing.cancel()
    await typing.value
    try await Task.sleep(for: .milliseconds(80))
    #expect(asked.withLock { $0 } == 0)
    #expect(board.draftPreview == nil)
  })
}

@MainActor
@Test func aFailedPreviewShowsNothingAndTheSaveStillGoes() async throws {
  let created = Mutex(false)
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/schedules/preview") == true { return json(#"{"error":"down"}"#, status: 503) }
    if request.httpMethod == "POST" {
      created.withLock { $0 = true }
      return json(wire("new", name: "Morning", cron: "0 9 * * *"), status: 201, delay: 0.05)
    }
    return json("[]")
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.name = "Morning"
    board.draft?.prompt = "Say hi"
    board.draft?.when = .daily
    await board.loadPreview(client: client, after: .zero)
    #expect(board.draftPreview == nil)
    board.saveDraft(client: client)
    #expect(board.saveError.isEmpty)
    #expect(board.schedules.first?.nextRunLabel == "Saving…")
    #expect(board.schedules.first?.description == "Saving…")
    try await wait { created.withLock { $0 } && board.isLoaded }
  })
}

@MainActor
@Test func aSavedRowRunsWhenThePreviewSaid() async throws {
  try await withClient(handler: { request in
    request.url?.path.hasSuffix("/schedules/preview") == true
      ? json(preview) : json(wire("new", cron: "0 9 * * *"), status: 201, delay: 0.05)
  }, test: { client in
    let board = AutomationBoard()
    board.openNew(agentID: "a1")
    board.draft?.name = "Morning"
    board.draft?.prompt = "Say hi"
    board.draft?.when = .daily
    await board.loadPreview(client: client, after: .zero)
    board.saveDraft(client: client)
    #expect(board.schedules.first?.nextRunAt == "2026-11-07T08:00:00.000Z")
  })
}

@MainActor
@Test func theListRefreshesItsLabelsWhileItIsShown() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { _ in
    reads.withLock { $0 += 1 }
    return json("[\(script)]")
  }, test: { client in
    let board = AutomationBoard()
    let following = Task { await board.follow(client: client, every: .milliseconds(10)) }
    try await wait { reads.withLock { $0 } >= 2 }
    #expect(board.schedules.first?.nextRunLabel == "soon")
    following.cancel()
    await following.value
  })
}
