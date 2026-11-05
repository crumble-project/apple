import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let avatar = #"{"definition":{"version":1,"id":"owl","name":"Owl","#
  + #""body":{"path":"M10 10H90V90H10Z"},"eyes":{"x":50,"y":40,"spacing":20,"scale":1}},"#
  + ##""color":"#112233","eyeColor":"#ffeedd"}"##

private func saved(_ status: String, avatar: String? = avatar, createdAgentID: String? = nil) -> String {
  let avatarField = avatar.map { #""avatar":\#($0),"# } ?? ""
  return #"{"id":"r1","agentId":"a1","reason":"Researching","status":"\#(status)","#
    + #""createdAgentId":\#(createdAgentID.map { "\"\($0)\"" } ?? "null"),"#
    + #""requestedAt":"2026-11-05T10:00:00Z","decidedAt":null,"proposal":{\#(avatarField)"#
    + #""name":"Scout","description":"Finds papers","instructions":"Be brief","provider":"openai","#
    + #""model":"gpt-test","webSearchProvider":"exa","enabled":true,"tools":["memory","web","create_bots"],"#
    + #""skills":[],"mcpServers":["11111111-1111-4111-8111-111111111111"],"delegates":[],"#
    + #""inference":{"thinkingLevel":"low","maxOutputTokens":500},"#
    + #""review":{"enabled":false,"skillThreshold":3,"memoryThreshold":4},"#
    + #""reviewModel":{"provider":"openai","model":"gpt-review"}}}"#
}

private let createdBot = #"{"id":"a2","name":"Scout","avatar":\#(avatar),"enabled":true,"provider":"openai","#
  + #""model":"gpt-test","instructions":"Be brief","description":"Finds papers","tools":[],"skills":[],"#
  + #""sharedSkills":[],"mcpServers":[],"delegates":[],"inference":{"thinkingLevel":"low"},"#
  + #""createdAt":"2026-11-05T10:00:00Z","updatedAt":"2026-11-05T10:00:00Z"}"#

private func toolResult(
  _ status: String = "pending", isError: Bool? = nil, avatar: String? = avatar
) throws -> Message {
  Message(
    id: "m1", role: "toolResult", toolName: BotRequest.toolName, isError: isError,
    toolDetails: try JSONDecoder().decode(JSONValue.self, from: Data(saved(status, avatar: avatar).utf8)))
}

private func list(_ status: String, createdAgentID: String? = nil) -> StubResponse {
  StubResponse(body: Data(("[" + saved(status, createdAgentID: createdAgentID) + "]").utf8))
}

private func refused(_ status: Int, _ message: String) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8))
}

private func approval() -> StubResponse {
  StubResponse(body: Data(
    (#"{"request":\#(saved("approved", createdAgentID: "a2")),"agent":\#(createdBot)}"#).utf8))
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

/// The read that follows a decision must land before the test's stub goes away.
@MainActor
private func stop(_ board: BotRequestBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(40))
}

@MainActor
private func showing(_ request: BotRequest, client: APIClient) async throws -> BotRequestBoard {
  let board = BotRequestBoard(pollInterval: .milliseconds(5))
  board.select("a1")
  board.refreshIfChanged(messages: [try toolResult()], client: client)
  try await Task.sleep(for: .milliseconds(30))
  return board
}

@Test func aRequestToolResultCarriesTheProposal() throws {
  let request = try #require(BotRequest(message: try toolResult()))
  #expect(request.id == "r1")
  #expect(request.agentID == "a1")
  #expect(request.reason == "Researching")
  #expect(request.status == .pending)
  #expect(request.proposal.name == "Scout")
  #expect(request.proposal.provider == "openai")
  #expect(request.proposal.inference?.maxOutputTokens == 500)
  #expect(request.proposal.avatar.definition.id == "owl")
  #expect(request.proposal.avatar.color == "#112233")
}

@Test func aProposalWithoutAnAvatarUsesTheStarterForItsRequest() throws {
  let request = try #require(BotRequest(message: try toolResult(avatar: nil)))
  #expect(request.proposal.avatar == .default(for: "r1"))
}

@Test func anInvalidProposedAvatarFallsBackToTheStarterGeometry() throws {
  let broken = avatar.replacingOccurrences(of: "M10 10H90V90H10Z", with: "not a path")
  let request = try #require(BotRequest(message: try toolResult(avatar: broken)))
  #expect(request.proposal.avatar.definition == BotAvatarDefinition.default(for: "r1").definition)
  #expect(request.proposal.avatar.color == "#112233")
}

@Test func onlyASuccessfulRequestResultIsACard() throws {
  #expect(BotRequest(message: try toolResult(isError: true)) == nil)
  var other = try toolResult()
  other.toolName = "memory"
  #expect(BotRequest(message: other) == nil)
  other = try toolResult()
  other.toolDetails = .object(["id": .string("r1")])
  #expect(BotRequest(message: other) == nil)
}

@Test func capabilitiesUseTheirNamesAndKnownServers() throws {
  let request = try #require(BotRequest(message: try toolResult()))
  let server = MCPServer(
    id: "11111111-1111-4111-8111-111111111111", name: "Papers", url: "https://mcp.example", enabled: true)
  #expect(request.capabilityNames(servers: []) == [
    "Memory", "Web search", "Create bots", "11111111-1111-4111-8111-111111111111"
  ])
  #expect(request.capabilityNames(servers: [server]).last == "Papers")
}

@Test func theDraftOfAProposalIsNewAndKeepsItsRequest() throws {
  let request = try #require(BotRequest(message: try toolResult()))
  var draft = AgentDraft(botRequest: request)
  #expect(draft.isNew)
  #expect(draft.botRequest == request)
  #expect(draft.name == "Scout")
  #expect(draft.avatar == request.proposal.avatar)
  #expect(draft.thinking == "low")
  #expect(draft.tools(keeping: request.proposal.tools ?? []).contains("create_bots"))
  #expect(draft.canApprove)
  draft.model = " "
  #expect(!draft.canApprove)
}

@MainActor @Test func theListReplacesTheSavedCopy() async throws {
  try await withClient(handler: { _ in list("declined") }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = BotRequestBoard()
    board.select("a1")
    #expect(board.current(request).status == .pending)
    board.refreshIfChanged(messages: [try toolResult()], client: client)
    #expect(board.needsPolling)
    try await wait { board.current(request).status == .declined }
    #expect(!board.needsPolling)
    try await stop(board)
  })
}

@MainActor @Test func aPollSeesARequestDecidedElsewhere() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { _ in
    reads.withLock { $0 += 1; return $0 } < 3 ? list("pending") : list("approved", createdAgentID: "a2")
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    let watch = Task { await board.watch(client: client) }
    defer { watch.cancel() }
    try await wait { board.current(request).status == .approved }
    #expect(board.current(request).createdAgentID == "a2")
    #expect(!board.needsPolling)
    watch.cancel()
    try await stop(board)
  })
}

@MainActor @Test func approvalShowsOnlyOnceTheServerConfirmsAndReportsTheBot() async throws {
  let confirmed = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      #expect(request.url?.path == "/prefix/v1/agents/a1/bot-requests/r1/approve")
      confirmed.withLock { $0 = true }
      return StubResponse(body: approval().body, delay: 0.1)
    }
    return confirmed.withLock { $0 } ? list("approved", createdAgentID: "a2") : list("pending")
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    var created: Agent?
    board.approve(request, client: client) { created = $0 }
    #expect(board.decision(for: "r1").sending)
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.current(request).status == .pending)
    try await wait { board.current(request).status == .approved }
    #expect(created?.id == "a2")
    #expect(!board.decision(for: "r1").sending)
    try await stop(board)
  })
}

@MainActor @Test func anEditedProposalKeepsWhatTheEditorDoesNotShow() async throws {
  let body = Mutex<JSONValue?>(nil)
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return list("pending") }
    let sent = try requestJSON(request)
    body.withLock { $0 = sent }
    return approval()
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    var edited = request.proposal
    edited.name = "Renamed"
    edited.description = nil
    edited.tools = ["memory"]
    edited.avatar.color = "#000000"
    board.approve(request, editedTo: edited, client: client) { _ in }
    try await wait { body.withLock { $0 != nil } }
    let proposal = try #require(body.withLock { $0 }?["proposal"])
    #expect(proposal["name"]?.stringValue == "Renamed")
    #expect(proposal["description"] == .string(""))
    #expect(proposal["tools"] == .array([.string("memory")]))
    #expect(proposal["avatar"]?["color"]?.stringValue == "#000000")
    #expect(proposal["avatar"]?["definition"]?["id"]?.stringValue == "owl")
    #expect(proposal["webSearchProvider"]?.stringValue == "exa")
    #expect(proposal["review"]?["skillThreshold"]?.numberValue == 3)
    #expect(proposal["reviewModel"]?["model"]?.stringValue == "gpt-review")
    try await stop(board)
  })
}

@MainActor @Test func approvingAsProposedSendsNoProposal() async throws {
  let bodies = Mutex<[Data?]>([])
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return list("pending") }
    bodies.withLock { $0.append(request.httpBody) }
    return approval()
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    board.approve(request, client: client) { _ in }
    try await wait { bodies.withLock { !$0.isEmpty } }
    #expect(bodies.withLock { $0 } == [nil])
    try await stop(board)
  })
}

@MainActor @Test func aRefusedBotRequestApprovalStaysWaitingWithTheError() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? refused(400, "Unknown provider") : list("pending")
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    var created: Agent?
    board.approve(request, client: client) { created = $0 }
    try await wait { !board.decision(for: "r1").error.isEmpty }
    #expect(board.decision(for: "r1").error == "Unknown provider")
    #expect(!board.decision(for: "r1").sending)
    #expect(board.current(request).status == .pending)
    #expect(created == nil)
    try await stop(board)
  })
}

@MainActor @Test func anAlreadyDecidedRequestSettlesToTheServersOutcome() async throws {
  let posted = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      posted.withLock { $0 = true }
      return refused(409, "Bot request has already been decided")
    }
    return list(posted.withLock { $0 } ? "declined" : "pending")
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    board.approve(request, client: client) { _ in }
    try await wait { board.current(request).status == .declined }
    try await stop(board)
  })
}

@MainActor @Test func declineSettlesOnceTheServerConfirms() async throws {
  let posted = Mutex(false)
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return list(posted.withLock { $0 } ? "declined" : "pending") }
    #expect(request.url?.path == "/prefix/v1/agents/a1/bot-requests/r1/decline")
    posted.withLock { $0 = true }
    return StubResponse(body: Data(saved("declined").utf8))
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    board.decline(request, client: client)
    #expect(board.decision(for: "r1").sending)
    try await wait { board.current(request).status == .declined }
    try await stop(board)
  })
}

@MainActor @Test func aListReadBeforeADecisionCannotUndoIt() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" { return approval() }
    return reads.withLock { $0 += 1; return $0 } == 2
      ? StubResponse(body: list("pending").body, delay: 0.1) : list("approved", createdAgentID: "a2")
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    board.refresh(client: client)
    board.approve(request, client: client) { _ in }
    try await wait { board.current(request).status == .approved }
    try await Task.sleep(for: .milliseconds(150))
    #expect(board.current(request).status == .approved)
    try await stop(board)
  })
}

@MainActor @Test func anApprovalLandingAfterTheOwnerMovedOnStillReportsTheBot() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? StubResponse(body: approval().body, delay: 0.05) : list("pending")
  }, test: { client in
    let request = try #require(BotRequest(message: try toolResult()))
    let board = try await showing(request, client: client)
    var created: Agent?
    board.approve(request, client: client) { created = $0 }
    board.select("a9")
    #expect(board.current(request).status == .pending)
    try await wait { created != nil }
    #expect(created?.id == "a2")
    #expect(board.current(request).status == .pending)
    try await stop(board)
  })
}
