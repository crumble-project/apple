import Foundation
import Synchronization
import Testing

@testable import apfelkern

private func decode(_ json: String) throws -> Message {
  try JSONDecoder().decode(Message.self, from: Data(json.utf8))
}

@Test func codingToolResultDecodesJob() throws {
  let message = try decode(
    #"{"id":"m1","role":"toolResult","toolName":"coding","#
      + #""toolDetails":{"name":"fix-login","status":"working","conversationId":"c1"}}"#)
  #expect(CodingJob(message: message) == CodingJob(name: "fix-login", conversationId: "c1", status: "working"))
  #expect(CodingJob(message: message)?.isWorking == true)
}

@Test func codingStatusListingIsNotAJob() throws {
  let message = try decode(#"{"id":"m1","role":"toolResult","toolName":"coding","content":"none"}"#)
  #expect(CodingJob(message: message) == nil)
}

@Test func codingOriginHasLabel() throws {
  let message = try decode(
    #"{"id":"m1","role":"user","content":"Done","origin":{"kind":"coding","name":"fix-login"}}"#)
  #expect(messageLabel(message) == "Coding job · fix-login")
}

private func step(_ id: String, result: String? = nil) -> String {
  let output = result.map {
    #","result":{"id":"r","entryId":"r","role":"toolResult","content":"\#($0)","replyReferences":[]}"#
  } ?? ""
  return #"{"kind":"step","id":"\#(id)","tool":"bash","label":"Ran","icon":"terminal","subject":"ls"\#(output)}"#
}

private func historyPage(_ items: [String], hasMore: Bool = false, oldest: String? = nil) -> StubResponse {
  let oldestJSON = oldest.map { #""\#($0)""# } ?? "null"
  let json = #"{"messages":[],"items":[\#(items.joined(separator: ","))],"#
    + #""hasMore":\#(hasMore),"oldestEntryId":\#(oldestJSON)}"#
  return StubResponse(body: Data(json.utf8))
}

@MainActor
private func waitFor(_ done: () -> Bool) async {
  for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
  #expect(done())
}

private func stepResult(_ history: JobHistory?, _ id: String) -> String? {
  history?.items.lazy.compactMap { item -> JobStepItem? in
    if case .step(let step) = item, step.id == id { step } else { nil }
  }.first?.result?.content
}

@Test func jobHistoryReadsTheServersItems() async throws {
  let task = #"{"kind":"task","id":"u","text":"Fix the build"}"#
  let reply = #"{"kind":"reply","id":"a:0","text":"Running tests."}"#
  try await withClient(handler: { _ in historyPage([task, reply, step("t1", result: "boom")]) }, test: { client in
    let page = try await client.jobHistory(.coding, agentID: "a1", name: "fix", before: "", limit: 100)
    #expect(page.items.map(\.id) == ["u", "a:0", "t1"])
    guard case .step(let bash) = page.items[2] else {
      Issue.record("expected a step")
      return
    }
    #expect(bash.label == "Ran" && bash.icon == .terminal && bash.subject == "ls")
    #expect(bash.finished && bash.shownOutput == "boom")
  })
}

@Test func shownOutputKeepsEveryLine() {
  func step(_ output: String?) -> JobStepItem {
    JobStepItem(
      icon: .terminal, id: "t", kind: .step, label: "Ran",
      result: output.map {
        Components.Schemas.TranscriptMessage(
          content: $0, entryId: "r", id: "r", replyReferences: [], role: "toolResult")
      }, tool: "bash")
  }
  let lines = (1...500).map(String.init).joined(separator: "\n")
  #expect(step(lines + "\n\n").shownOutput == lines)
  #expect(step("\n").shownOutput == "No output.")
  #expect(!step(nil).finished)
}

@Test @MainActor func aStepTheNewestPageScrolledPastStillGetsItsResult() async throws {
  let shifted = Mutex(false)
  try await withClient(handler: { request in
    let before = request.url?.query?.contains("before=2") == true
    if before { return historyPage([step("call", result: "done")]) }
    return shifted.withLock { $0 }
      ? historyPage([#"{"kind":"task","id":"2","text":"Next"}"#], hasMore: true, oldest: "2")
      : historyPage([step("call")])
  }, test: { client in
    let board = JobBoard()
    board.open(.coding, "fix", agentID: "a1", client: client)
    await waitFor { board.history?.loaded == true }
    #expect(stepResult(board.history, "call") == nil)

    shifted.withLock { $0 = true }
    board.loadHistory(client: client)
    await waitFor { stepResult(board.history, "call") != nil }
    #expect(stepResult(board.history, "call") == "done")
    #expect(board.history?.items.map(\.id) == ["call", "2"])
  })
}

@Test @MainActor func anEarlierPagesStepGetsItsResultWhenItArrives() async throws {
  let finished = Mutex(false)
  try await withClient(handler: { request in
    guard request.url?.query?.contains("before=2") == true else {
      return historyPage([#"{"kind":"task","id":"2","text":"Next"}"#], hasMore: true, oldest: "2")
    }
    return historyPage([finished.withLock { $0 } ? step("call", result: "done") : step("call")])
  }, test: { client in
    let board = JobBoard()
    board.open(.coding, "fix", agentID: "a1", client: client)
    await waitFor { board.history?.loaded == true }
    board.loadOlderHistory(client: client)
    await waitFor { board.history?.items.count == 2 }
    #expect(stepResult(board.history, "call") == nil)

    finished.withLock { $0 = true }
    board.loadHistory(client: client)
    await waitFor { stepResult(board.history, "call") != nil }
    #expect(stepResult(board.history, "call") == "done")
  })
}

@Test(arguments: [false, true])
@MainActor func slowHistoryLoadsFinishWhileTheJobIsPolled(olderPage: Bool) async throws {
  let requests = Mutex((listings: 0, newest: 0, older: 0))
  try await withClient(handler: { request in
    if request.url?.lastPathComponent == "coding-jobs" {
      requests.withLock { $0.listings += 1 }
      return StubResponse(body: Data(
        #"{"jobs":[{"name":"fix","conversationId":"c1","status":"working"}]}"#.utf8))
    }
    if request.url?.query?.contains("before=2") == true {
      requests.withLock { $0.older += 1 }
      return StubResponse(body: historyPage([step("call", result: "done")]).body, delay: 0.2)
    }
    let load = requests.withLock { $0.newest += 1; return $0.newest }
    if load == 1 { return historyPage([step("call")]) }
    if olderPage {
      return historyPage([#"{"kind":"task","id":"2","text":"Next"}"#], hasMore: true, oldest: "2")
    }
    return StubResponse(body: historyPage([step("call", result: "done")]).body, delay: 0.2)
  }, test: { client in
    let board = JobBoard()
    board.refresh(.coding, agentID: "a1", client: client)
    await waitFor { board.jobs["coding/fix"]?.isWorking == true }
    board.open(.coding, "fix", agentID: "a1", client: client)
    await waitFor { board.history?.loaded == true }

    let watcher = Task { await board.watch(every: .milliseconds(10), agentID: "a1", client: client) }
    defer { watcher.cancel() }
    await waitFor { requests.withLock { olderPage ? $0.older > 0 : $0.newest > 1 } }
    let listings = requests.withLock { $0.listings }
    await waitFor { requests.withLock { $0.listings >= listings + 4 } }
    #expect(requests.withLock { $0.newest } == 2)
    #expect(requests.withLock { $0.older } == (olderPage ? 1 : 0))
    #expect(stepResult(board.history, "call") == nil)

    await waitFor { stepResult(board.history, "call") == "done" }
    #expect(board.jobs["coding/fix"]?.isWorking == true)
    await waitFor { requests.withLock { $0.newest >= 3 } }
  })
}

@Test @MainActor func anOlderHistoryLoadThatFinishesLateIsDropped() async throws {
  let loads = Mutex(0)
  try await withClient(handler: { _ in
    switch loads.withLock({ $0 += 1; return $0 }) {
    case 1: historyPage([step("call")])
    case 2: StubResponse(body: historyPage([step("call")]).body, delay: 0.2)
    default: historyPage([step("call", result: "done"), #"{"kind":"task","id":"3","text":"Next"}"#])
    }
  }, test: { client in
    let board = JobBoard()
    board.open(.coding, "fix", agentID: "a1", client: client)
    await waitFor { board.history?.loaded == true }
    board.loadHistory(client: client)
    try await Task.sleep(for: .milliseconds(20))
    board.loadHistory(client: client)
    await waitFor { board.history?.items.count == 2 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(board.history?.items.map(\.id) == ["call", "3"])
    #expect(stepResult(board.history, "call") == "done")
  })
}

@Test @MainActor func aFailedOlderPageKeepsTheNewestPage() async throws {
  let refreshed = Mutex(false)
  try await withClient(handler: { request in
    let older = request.url?.query?.contains("before=2") == true
    guard refreshed.withLock({ $0 }) else {
      return older ? historyPage([step("call")]) : historyPage([#"{"kind":"task","id":"2","text":"Next"}"#],
        hasMore: true, oldest: "2")
    }
    if older { return StubResponse(status: 503, body: Data()) }
    return historyPage(
      [#"{"kind":"task","id":"2","text":"Next"}"#, #"{"kind":"task","id":"3","text":"Then"}"#], hasMore: true,
      oldest: "2")
  }, test: { client in
    let board = JobBoard()
    board.open(.coding, "fix", agentID: "a1", client: client)
    await waitFor { board.history?.loaded == true }
    board.loadOlderHistory(client: client)
    await waitFor { board.history?.items.count == 2 }

    refreshed.withLock { $0 = true }
    board.loadHistory(client: client)
    await waitFor { board.history?.items.count == 3 }
    #expect(board.history?.items.map(\.id) == ["call", "2", "3"])
    #expect(board.history?.error == "")
  })
}

@Test func draftDefaultsCodingOff() {
  #expect(AgentDraft(isNew: true, agentID: "").toolsCoding == false)
}

@Test func jobQuestionEventDecodes() throws {
  let message = try decode(
    #"{"id":"m1","role":"event","kind":"job-question","content":"Which DB?","#
      + #""jobQuestion":{"id":"q1","kind":"coding","job":"fix-login"}}"#)
  #expect(message.jobQuestion == JobQuestionEvent(id: "q1", kind: "coding", job: "fix-login"))
}

@Test func answerListsPickedOptionsInOrderThenWrittenText() {
  let question = JobQuestion(id: "q", text: "Which?", options: ["a", "b", "c"], multiple: true)
  var answer = JobAnswer()
  #expect(answer.reply(to: question).isEmpty)
  answer.picked = ["c", "a"]
  answer.text = "  also d\n"
  #expect(answer.reply(to: question) == "a, c\nalso d")
}

@Test func jobSummaryNamesTheModelAndLeavesOutZeroCost() {
  let usage = JobUsage(inputTokens: 1000, outputTokens: 500, cachedTokens: 0, cost: 0)
  let job = Job(kind: .coding, name: "fix", status: "idle", usage: usage, model: "gpt-6")
  #expect(job.summary(locale: Locale(identifier: "en_US")) == "gpt-6 · 1,000 in · 500 out")
  #expect(Job(kind: .coding, name: "fix", status: "idle").summary().isEmpty)
}

@Test func transcriptFencesOutputLongerThanItsBackticks() throws {
  let call = #"{"type":"toolCall","id":"t1","name":"read","arguments":{"path":"a/b"}}"#
  let messages = try [
    decode(#"{"id":"u","role":"user","content":"Fix it"}"#),
    decode(#"{"id":"a","role":"assistant","blocks":[{"type":"text","text":"Reading."},"# + call + "]}"),
    decode(#"{"id":"r","role":"toolResult","toolCallId":"t1","content":"````x","isError":true}"#)
  ]
  let transcript = JobTranscript(kind: .coding, name: "fix", messages: messages)
  #expect(transcript.filename == "fix.md")
  #expect(transcript.markdown == """
    # fix

    Coding job

    ## Task

    Fix it

    Reading.

    ### read

    ```json
    {
      "path" : "a/b"
    }
    ```

    Failed:

    `````
    ````x
    `````

    """)
}
