import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func saved(
  _ status: String, outcome: String? = nil, callID: String? = nil, id: String = "r1"
) -> String {
  #"{"id":"\#(id)","agentId":"a1","number":"+4930123456","callee":"Dr. Weber","goal":"Book a visit","#
    + #""opening":"Hello, this is Bot.","status":"\#(status)","#
    + #""callId":\#(callID.map { "\"\($0)\"" } ?? "null"),"conversationId":null,"#
    + #""outcome":\#(outcome.map { "\"\($0)\"" } ?? "null"),"error":null,"#
    + #""requestedAt":"2026-11-05T10:00:00Z","decidedAt":null,"endedAt":null}"#
}

private func toolResult(_ status: String = "pending", isError: Bool? = nil) throws -> Message {
  Message(
    id: "m1", role: "toolResult", toolName: CallRequest.toolName, isError: isError,
    toolDetails: try JSONDecoder().decode(JSONValue.self, from: Data(saved(status).utf8)))
}

private func list(_ status: String) -> StubResponse {
  StubResponse(body: Data(("[" + saved(status) + "]").utf8))
}

private func refused(_ status: Int, _ message: String) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8))
}

private func request(
  _ status: CallRequest.Status = .ended, outcome: CallRequest.Outcome? = nil, id: String = "r1",
  callID: String? = nil
) throws -> CallRequest {
  var request = try #require(CallRequest(message: try toolResult()))
  request.id = id
  request.status = status
  request.outcome = outcome
  request.callID = callID
  return request
}

private func notice(_ requestID: String?, _ content: String, kind: String = "call") -> Message {
  Message(id: "n", role: "user", content: .string(content), origin: MessageOrigin(kind: kind), requestId: requestID)
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

@MainActor
private func stop(_ board: CallRequestBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(40))
}

@MainActor
private func showing(client: APIClient) async throws -> CallRequestBoard {
  let board = CallRequestBoard(pollInterval: .milliseconds(5))
  board.select("a1")
  board.refreshIfChanged(messages: [try toolResult()], client: client)
  try await Task.sleep(for: .milliseconds(30))
  return board
}

@Test func aCallRequestToolResultCarriesTheRequest() throws {
  let request = try #require(CallRequest(message: try toolResult()))
  #expect(request.id == "r1")
  #expect(request.agentID == "a1")
  #expect(request.callee == "Dr. Weber")
  #expect(request.number == "+4930123456")
  #expect(request.goal == "Book a visit")
  #expect(request.opening == "Hello, this is Bot.")
  #expect(request.status == .pending)
  #expect(request.callID == nil)
  #expect(request.outcome == nil)
  #expect(shownInChat(try toolResult()))
}

@Test func onlyASuccessfulCallRequestResultIsACard() throws {
  #expect(CallRequest(message: try toolResult(isError: true)) == nil)
  var other = try toolResult()
  other.toolName = "memory"
  #expect(CallRequest(message: other) == nil)
  other = try toolResult()
  other.toolDetails = .object(["id": .string("r1")])
  #expect(CallRequest(message: other) == nil)
}

@Test func anUnknownStatusOrOutcomeIsNotACardAndFailsTheReadWithoutCrashing() async throws {
  #expect(CallRequest(message: try toolResult("paused")) == nil)
  try await withClient(handler: { _ in list("paused") }, test: { client in
    await #expect(throws: (any Error).self) { try await client.callRequests("a1") }
  })
}

@Test func anEndedRequestReadsItsOutcome() async throws {
  let body = saved("ended", outcome: "busy", callID: "c1")
  try await withClient(handler: { _ in StubResponse(body: Data(("[" + body + "]").utf8)) }, test: { client in
    let request = try #require(try await client.callRequests("a1").first)
    #expect(request.status == .ended)
    #expect(request.outcome == .busy)
    #expect(request.callID == "c1")
  })
}

@Test(arguments: [
  (CallRequest.Status.pending, CallRequest.Outcome?.none, String?.none),
  (.declined, nil, "Declined"),
  (.calling, nil, "Calling"),
  (.ended, .answered, "Answered"),
  (.ended, .unanswered, "Not answered"),
  (.ended, .busy, "Busy"),
  (.ended, .failed, "Failed"),
  (.ended, nil, "Ended")
])
func aRequestNamesItsState(status: CallRequest.Status, outcome: CallRequest.Outcome?, label: String?) throws {
  #expect(try request(status, outcome: outcome).stateLabel == label)
}

@Test func aCallStartedEventForAnOutsideCallIsNotShown() {
  func started(callee: String?) -> Message {
    Message(
      id: "e", role: "event", content: .string("Hello"), kind: CallMarker.startedKind,
      call: CallEvent(callId: "c1", direction: .outbound, callee: callee))
  }
  #expect(!shownInChat(started(callee: "Dr. Weber")))
  #expect(shownInChat(started(callee: nil)))
}

@Test func aCalleeSurvivesDecoding() throws {
  let json = #"{"callId":"c1","direction":"outbound","callee":"Dr. Weber"}"#
  #expect(try JSONDecoder().decode(CallEvent.self, from: Data(json.utf8)).callee == "Dr. Weber")
}

@Test func anEndNoticeBelongsToTheRequestOfItsCall() throws {
  let requests = [try request(id: "r1", callID: "c1"), try request(id: "r2", callID: "c2")]
  #expect(callRequest(for: notice("voice-call:c2:ended", "x"), in: requests)?.id == "r2")
  #expect(callRequest(for: notice("voice-call:other:ended", "x"), in: requests) == nil)
  #expect(callRequest(for: notice("voice-call:c2:started", "x"), in: requests) == nil)
}

@Test func aSweptNoticeBelongsToItsRequest() throws {
  let requests = [try request(id: "r1"), try request(id: "r2")]
  #expect(callRequest(for: notice("call-request:r2", "x"), in: requests)?.id == "r2")
  #expect(callRequest(for: notice("call-request:r9", "x"), in: requests) == nil)
  #expect(callRequest(for: notice(nil, "x"), in: requests) == nil)
  #expect(callRequest(for: notice("call-request:r2", "x", kind: "task"), in: requests) == nil)
  #expect(callRequest(for: notice("call-request:r2", "x", kind: "call_request"), in: requests)?.id == "r2")
}

@Test func aNoticeDetailDropsTheLeadingCallTo() throws {
  let request = try request()
  #expect(callNoticeDetail(notice("call-request:r1", "Call to Dr. Weber ended after 2 minutes."), request: request)
    == "ended after 2 minutes.")
  #expect(callNoticeDetail(notice("call-request:r1", "Could not reach anyone."), request: request)
    == "Could not reach anyone.")
}

@Test func aCallRequestNoticeIsTitled() {
  #expect(noticeTitle(notice("call-request:r1", "x", kind: "call_request")) == "Call request")
  #expect(noticeTitle(notice(nil, "x", kind: "bot_request")) == "Bot request")
}

@Test func theTranscriptKeepsWhatWasSaid() {
  let blocks = JSONValue.array([.object(["type": .string("text"), "text": .string("Hi")])])
  let silent = JSONValue.array([.object(["type": .string("toolCall")])])
  let lines = callTranscriptLines([
    Message(id: "1", role: "user", content: .string("Hello?")),
    Message(id: "2", role: "assistant", content: .string("Hi"), blocks: blocks),
    Message(id: "3", role: "assistant", content: .string(""), blocks: silent),
    Message(id: "4", role: "toolResult", content: .string("x")),
    Message(id: "5", role: "event", content: .string("x"))
  ])
  #expect(lines == [
    CallTranscriptLine(id: "1", speaker: .callee, text: "Hello?"),
    CallTranscriptLine(id: "2", speaker: .bot, text: "Hi")
  ])
}

@Test func theTranscriptComesFromItsEndpoint() async throws {
  try await withClient(handler: { request in
    #expect(request.url?.path == "/prefix/v1/agents/a1/call-requests/r1/transcript")
    return StubResponse(body: Data(
      #"{"messages":[{"id":"m1","entryId":"e1","role":"user","content":"Hello?"}],"hasMore":false}"#.utf8))
  }, test: { client in
    let page = try await client.callRequestTranscript("a1", id: "r1")
    #expect(page.messages?.map(\.id) == ["m1"])
    #expect(page.hasMore == false)
  })
}

@MainActor @Test func theListReplacesTheSavedCopyAndPollsWhileOpen() async throws {
  try await withClient(handler: { _ in list("calling") }, test: { client in
    let request = try #require(CallRequest(message: try toolResult()))
    let board = CallRequestBoard()
    board.select("a1")
    #expect(board.current(request).status == .pending)
    board.refreshIfChanged(messages: [try toolResult()], client: client)
    #expect(board.needsPolling)
    try await wait { board.current(request).status == .calling }
    #expect(board.needsPolling)
    try await stop(board)
  })
}

@MainActor @Test func aSettledListNeedsNoPolling() async throws {
  try await withClient(handler: { _ in list("declined") }, test: { client in
    let board = try await showing(client: client)
    try await wait { board.requests.first?.status == .declined }
    #expect(!board.needsPolling)
    try await stop(board)
  })
}

@MainActor @Test func approvalShowsPendingAtOnceAndSettlesOnlyOnceTheServerConfirms() async throws {
  let confirmed = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      #expect(request.url?.path == "/prefix/v1/agents/a1/call-requests/r1/approve")
      confirmed.withLock { $0 = true }
      return StubResponse(body: Data(saved("calling").utf8), delay: 0.1)
    }
    return confirmed.withLock { $0 } ? list("calling") : list("pending")
  }, test: { client in
    let request = try #require(CallRequest(message: try toolResult()))
    let board = try await showing(client: client)
    board.approve(request, client: client)
    #expect(board.decision(for: "r1").sending)
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.current(request).status == .pending)
    try await wait { board.current(request).status == .calling }
    #expect(!board.decision(for: "r1").sending)
    try await stop(board)
  })
}

@MainActor @Test func aRefusedApprovalRestoresTheRequestWithTheServersText() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? refused(409, "The voice gateway is not set up") : list("pending")
  }, test: { client in
    let request = try #require(CallRequest(message: try toolResult()))
    let board = try await showing(client: client)
    board.approve(request, client: client)
    try await wait { !board.decision(for: "r1").error.isEmpty }
    #expect(board.decision(for: "r1").error == "The voice gateway is not set up")
    #expect(!board.decision(for: "r1").sending)
    #expect(board.current(request).status == .pending)
    #expect(board.needsPolling)
    try await stop(board)
  })
}

@MainActor @Test func decliningACallShowsPendingUntilTheServerConfirms() async throws {
  let posted = Mutex(false)
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return list(posted.withLock { $0 } ? "declined" : "pending") }
    #expect(request.url?.path == "/prefix/v1/agents/a1/call-requests/r1/decline")
    posted.withLock { $0 = true }
    return StubResponse(body: Data(saved("declined").utf8))
  }, test: { client in
    let request = try #require(CallRequest(message: try toolResult()))
    let board = try await showing(client: client)
    board.decline(request, client: client)
    #expect(board.decision(for: "r1").sending)
    #expect(board.current(request).status == .pending)
    try await wait { board.current(request).status == .declined }
    try await stop(board)
  })
}
