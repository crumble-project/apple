import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func action(_ status: String, id: String = "h1") -> String {
  #"{"id":"\#(id)","job":"checkout","action":"Pay 12 EUR","page":"https://shop.example/cart","#
    + #""ownerMessages":[{"requestId":"r1","text":"Buy it","from":"automation"}],"#
    + #""reason":"The amount was not named","status":"\#(status)","declineReason":null,"#
    + #""heldAt":"2026-11-05T10:00:00Z","decidedAt":null}"#
}

private func list(_ statuses: String...) -> StubResponse {
  StubResponse(body: Data(("[" + statuses.map { action($0) }.joined(separator: ",") + "]").utf8))
}

private func refused(_ status: Int, _ message: String) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8))
}

private let heldEvent = Message(
  id: "m1", role: "event", content: .string("Held: Pay 12 EUR"), kind: HeldActionEvent.messageKind,
  heldAction: HeldActionEvent(id: "h1", job: "checkout"))

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

/// The read that follows a decision must land before the test's stub goes away.
@MainActor
private func stop(_ board: HeldActionBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(40))
}

@MainActor
private func waiting(_ client: APIClient, agent: String = "a1") async throws -> HeldActionBoard {
  let board = HeldActionBoard(pollInterval: .milliseconds(5))
  board.select(agent)
  board.refreshIfChanged(messages: [heldEvent], client: client)
  #expect(board.state(of: "h1") == .outcome("Loading…"))
  try await wait {
    if case .waiting = board.state(of: "h1") { return true }
    return false
  }
  return board
}

@MainActor @Test func aHeldActionCarriesWhatTheOwnerDecidesOn() async throws {
  try await withClient(handler: { _ in list("pending") }, test: { client in
    let board = try await waiting(client)
    guard case let .waiting(held) = board.state(of: "h1") else { return }
    #expect(held.job == "checkout")
    #expect(held.action == "Pay 12 EUR")
    #expect(held.page == "https://shop.example/cart")
    #expect(held.reason == "The amount was not named")
    #expect(held.ownerMessages == [.init(requestID: "r1", text: "Buy it", fromAutomation: true)])
  })
}

@MainActor @Test(arguments: [("approved", "Approved"), ("declined", "Declined"), ("expired", "Expired")])
func aDecidedActionSettlesItsCard(status: String, outcome: String) async throws {
  try await withClient(handler: { _ in list(status) }, test: { client in
    let board = HeldActionBoard()
    board.select("a1")
    board.refreshIfChanged(messages: [heldEvent], client: client)
    try await wait { board.state(of: "h1") == .outcome(outcome) }
    #expect(!board.needsPolling)
  })
}

@MainActor @Test func anActionMissingFromTheListIsUnavailable() async throws {
  try await withClient(handler: { _ in list() }, test: { client in
    let board = HeldActionBoard()
    board.select("a1")
    board.refreshIfChanged(messages: [heldEvent], client: client)
    try await wait { board.state(of: "h1") == .outcome("Unavailable") }
  })
}

@MainActor @Test func aFailedReadIsUnavailableUntilAPollAnswers() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { _ in
    reads.withLock { $0 += 1; return $0 } == 1 ? refused(503, "Unavailable") : list("declined")
  }, test: { client in
    let board = HeldActionBoard(pollInterval: .milliseconds(5))
    board.select("a1")
    board.refreshIfChanged(messages: [heldEvent], client: client)
    try await wait { board.state(of: "h1") == .outcome("Unavailable") }
    #expect(board.needsPolling)
    let watch = Task { await board.watch(client: client) }
    defer { watch.cancel() }
    try await wait { board.state(of: "h1") == .outcome("Declined") }
  })
}

@MainActor @Test func aListThatPredatesTheEventKeepsTheCardLoading() async throws {
  let lists = Mutex(["[]"])
  try await withClient(handler: { _ in
    // A slow first read can land after the test swaps the list, so the last answer repeats.
    StubResponse(body: Data(lists.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }.utf8))
  }, test: { client in
    let board = HeldActionBoard()
    board.select("a1")
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.state(of: "h1") == .outcome("Loading…"))
    lists.withLock { $0 = ["[" + action("pending") + "]"] }
    board.refreshIfChanged(messages: [heldEvent], client: client)
    try await wait { board.state(of: "h1") != .outcome("Loading…") }
    if case .waiting = board.state(of: "h1") {} else { Issue.record("expected the action to wait") }
  })
}

@MainActor @Test func approvalShowsOnlyOnceTheServerConfirms() async throws {
  let confirmed = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      #expect(request.url?.path == "/prefix/v1/agents/a1/held-actions/h1/approve")
      confirmed.withLock { $0 = true }
      return StubResponse(body: Data(action("approved").utf8), delay: 0.1)
    }
    return list(confirmed.withLock { $0 } ? "approved" : "pending")
  }, test: { client in
    let board = try await waiting(client)
    board.approve("h1", client: client)
    #expect(board.decision(for: "h1").sending)
    try await Task.sleep(for: .milliseconds(30))
    if case .waiting = board.state(of: "h1") {} else { Issue.record("shown decided before the server said so") }
    try await wait { board.state(of: "h1") == .outcome("Approved") }
    try await stop(board)
  })
}

@MainActor @Test func aRefusedApprovalStaysWaitingWithTheError() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? refused(503, "The desktop is unreachable") : list("pending")
  }, test: { client in
    let board = try await waiting(client)
    board.approve("h1", client: client)
    try await wait { !board.decision(for: "h1").error.isEmpty }
    #expect(board.decision(for: "h1").error == "The desktop is unreachable")
    #expect(!board.decision(for: "h1").sending)
    if case .waiting = board.state(of: "h1") {} else { Issue.record("a refused approval left the choice") }
    try await stop(board)
  })
}

@MainActor @Test func anAlreadyDecidedActionSettlesToTheServersOutcome() async throws {
  let posted = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      posted.withLock { $0 = true }
      return refused(409, "The action was already decided")
    }
    return list(posted.withLock { $0 } ? "expired" : "pending")
  }, test: { client in
    let board = try await waiting(client)
    board.approve("h1", client: client)
    try await wait { board.state(of: "h1") == .outcome("Expired") }
    try await stop(board)
  })
}

@MainActor @Test func aFailedDeclineKeepsTheReasonAndTheNextSendsItTrimmed() async throws {
  let posts = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return list(posts.withLock { $0.count } < 2 ? "pending" : "declined") }
    #expect(request.url?.path == "/prefix/v1/agents/a1/held-actions/h1/decline")
    let body = try requestJSON(request)
    let count = posts.withLock { $0.append(body); return $0.count }
    return count == 1 ? refused(503, "Try later") : StubResponse(body: Data(action("declined").utf8))
  }, test: { client in
    let board = try await waiting(client)
    board.decisions["h1", default: HeldActionDecision()].declining = true
    board.decisions["h1"]?.reason = "  too expensive "
    board.decline("h1", client: client)
    try await wait { board.decision(for: "h1").error == "Try later" }
    #expect(board.decision(for: "h1").reason == "  too expensive ")
    #expect(board.decision(for: "h1").declining)
    board.decline("h1", client: client)
    try await wait { board.state(of: "h1") == .outcome("Declined") }
    #expect(posts.withLock { $0 }.last == .object(["reason": .string("too expensive")]))
    try await stop(board)
  })
}

@MainActor @Test func aDeclineWithoutAReasonOmitsIt() async throws {
  let body = Mutex<JSONValue?>(nil)
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return list(body.withLock { $0 } == nil ? "pending" : "declined") }
    let sent = try requestJSON(request)
    body.withLock { $0 = sent }
    return StubResponse(body: Data(action("declined").utf8))
  }, test: { client in
    let board = try await waiting(client)
    board.decline("h1", client: client)
    try await wait { board.state(of: "h1") == .outcome("Declined") }
    #expect(body.withLock { $0 } == .object([:]))
    try await stop(board)
  })
}

@MainActor @Test func aReadFromBeforeTheDecisionDoesNotReopenIt() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" { return StubResponse(body: Data(action("approved").utf8)) }
    let read = reads.withLock { $0 += 1; return $0 }
    if read == 2 { return StubResponse(body: list("pending").body, delay: 0.05) }
    return StubResponse(body: list(read < 2 ? "pending" : "approved").body, delay: read > 2 ? 0.1 : 0)
  }, test: { client in
    let board = try await waiting(client)
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(20))
    board.approve("h1", client: client)
    try await wait { board.state(of: "h1") == .outcome("Approved") }
    try await Task.sleep(for: .milliseconds(60))
    #expect(reads.withLock { $0 } == 3)
    #expect(board.state(of: "h1") == .outcome("Approved"))
    try await Task.sleep(for: .milliseconds(120))
    try await stop(board)
  })
}

@MainActor @Test func aDecisionThatReturnsAfterTheBotChangedIsDropped() async throws {
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      return StubResponse(body: Data(action("approved").utf8), delay: 0.05)
    }
    return list("pending")
  }, test: { client in
    let board = try await waiting(client)
    board.approve("h1", client: client)
    board.select("a2")
    try await Task.sleep(for: .milliseconds(120))
    #expect(board.state(of: "h1") == .outcome("Loading…"))
    #expect(board.decisions.isEmpty)
  })
}

@MainActor @Test func reopeningTheChatReadsWaitingActionsAnewAndKeepsTheDraftedReason() async throws {
  try await withClient(handler: { _ in list("pending") }, test: { client in
    let board = try await waiting(client)
    board.decisions["h1", default: HeldActionDecision()].reason = "no"
    board.select("a1")
    #expect(board.state(of: "h1") == .outcome("Loading…"))
    #expect(board.decision(for: "h1").reason == "no")
  })
}

@Test func aTranscriptMessageCarriesItsHeldAction() throws {
  let json = #"{"id":"m1","role":"event","kind":"held-action","content":"Held","#
    + #""heldAction":{"id":"h1","job":"checkout"}}"#
  let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
  #expect(message.heldAction == HeldActionEvent(id: "h1", job: "checkout"))
}
