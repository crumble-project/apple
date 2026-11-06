import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let typed = "made-up-token"

private func account(id: String = "g1", login: String = "crumble-machine", bots: [String] = []) -> String {
  let ids = bots.map { #""\#($0)""# }.joined(separator: ",")
  return #"{"id":"\#(id)","login":"\#(login)","htmlUrl":"https://github.com/\#(login)","botIds":[\#(ids)],"#
    + #""token":{"configured":true,"passwordManager":null,"reference":null},"#
    + #""signingKey":"ssh-ed25519 AAAAmadeup","createdAt":"2026-11-05T10:00:00Z"}"#
}

private func list(_ accounts: String...) -> StubResponse {
  StubResponse(body: Data(#"{"accounts":[\#(accounts.joined(separator: ","))]}"#.utf8))
}

private func one(_ json: String, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(body: Data(json.utf8), delay: delay)
}

private func refused(_ status: Int, _ message: String, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8), delay: delay)
}

private let noManagers = StubResponse(body: Data(#"{"passwordManagers":[]}"#.utf8))

private func isManagers(_ request: URLRequest) -> Bool {
  request.url?.path.hasSuffix("/password-managers") == true
}

private func isList(_ request: URLRequest) -> Bool {
  request.httpMethod == "GET" && request.url?.path.hasSuffix("/github-accounts") == true
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

/// The read that follows a write must land before the test's stub goes away.
@MainActor
private func stop(_ board: GitHubAccountBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(300))
}

@MainActor
private func loaded(_ board: GitHubAccountBoard, client: APIClient) async throws {
  board.refresh(client: client)
  try await wait { board.isLoaded }
}

@Test func theDraftKeepsTheTokenOutOfItsDescriptionAndDump() {
  var draft = GitHubAccountDraft()
  #expect(!draft.isReady)
  draft.token.value = typed
  #expect(draft.isReady)
  var dumped = ""
  dump(draft, to: &dumped)
  #expect(!dumped.contains(typed))
  #expect(!String(describing: draft).contains(typed))
  draft.clearSecrets()
  #expect(draft.token.value.isEmpty)
  #expect(!draft.isReady)
}

@Test func anExistingAccountKeepsItsTokenAndOnlySendsARealChange() {
  let saved = SecretStatus(configured: true, passwordManager: .onePassword, reference: "op://v/i/token")
  let existing = GitHubAccount(
    id: "g1", login: "crumble-machine", htmlUrl: "https://github.com/crumble-machine", botIds: ["a1"],
    token: saved, signingKey: "ssh-ed25519 AAAAmadeup")
  var draft = GitHubAccountDraft(existing: existing)
  #expect(draft.isReady)
  #expect(draft.tokenLabel == "Token")
  #expect(!draft.checksToken)
  #expect(!draft.changesBots)
  draft.botIDs.insert("a2")
  #expect(draft.changesBots)
  draft.token.reference = "op://v/i/other"
  #expect(draft.checksToken)
}

@MainActor @Test func addingWaitsForGitHubAndAFailureKeepsTheSheet() async throws {
  let refuse = Mutex(true)
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return refuse.withLock { $0 } ? list() : list(account()) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return refuse.withLock { $0 }
      ? refused(400, "GitHub refused this token; check that it hasn't expired", delay: 0.05)
      : one(account(), delay: 0.05)
  }, test: { client in
    let board = GitHubAccountBoard()
    try await loaded(board, client: client)
    board.startNew(client: client)
    board.draft?.token.value = typed
    board.saveDraft(client: client)
    #expect(board.isSaving)
    board.closeDraft()
    #expect(board.draft != nil)
    #expect(board.accounts.isEmpty)
    try await wait { !board.isSaving }
    #expect(board.saveError.contains("GitHub refused"))
    #expect(board.draft?.token.value == typed)

    refuse.withLock { $0 = false }
    board.saveDraft(client: client)
    try await wait { !board.isSaving }
    #expect(board.draft == nil)
    #expect(board.saveError.isEmpty)
    #expect(board.accounts.map(\.login) == ["crumble-machine"])
    #expect(bodies.withLock { $0 } == [.object(["value": .string(typed)]), .object(["value": .string(typed)])])
    try await stop(board)
  })
}

@MainActor @Test func aRetryAfterAFailedAssignmentDoesNotSendTheTokenAgain() async throws {
  let tokenPuts = Mutex(0)
  let refuse = Mutex(true)
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return list(account()) }
    if request.url?.path.hasSuffix("/token") == true {
      tokenPuts.withLock { $0 += 1 }
      return one(account())
    }
    return refuse.withLock { $0 } ? refused(409, "Atlas already acts as another") : one(account(bots: ["a1"]))
  }, test: { client in
    let board = GitHubAccountBoard()
    try await loaded(board, client: client)
    board.edit(try #require(board.accounts.first), client: client)
    board.draft?.token.value = typed
    board.draft?.botIDs = ["a1"]
    board.saveDraft(client: client)
    try await wait { !board.isSaving && !board.saveError.isEmpty }
    #expect(board.saveError.contains("already acts"))
    #expect(board.draft?.token.value.isEmpty == true)
    #expect(board.draft?.botIDs == ["a1"])

    refuse.withLock { $0 = false }
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    try await wait { board.accounts.first?.botIds == ["a1"] }
    #expect(tokenPuts.withLock { $0 } == 1)
    try await stop(board)
  })
}

@MainActor @Test func assigningBotsShowsAtOnceAndComesBackOnFailure() async throws {
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return list(account()) }
    return refused(409, "Atlas already acts as another", delay: 0.05)
  }, test: { client in
    let board = GitHubAccountBoard()
    try await loaded(board, client: client)
    let saved = try #require(board.accounts.first)
    board.edit(saved, client: client)
    board.draft?.botIDs = ["a1"]
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(board.accounts.first?.botIds == ["a1"])
    #expect(board.isUnconfirmed(saved))
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(20))
    #expect(board.accounts.first?.botIds == ["a1"])

    try await wait { board.draft != nil }
    #expect(board.saveError.contains("already acts"))
    #expect(board.draft?.botIDs == ["a1"])
    #expect(board.accounts.first?.botIds == [])
    #expect(!board.isUnconfirmed(saved))
    try await stop(board)
  })
}

@MainActor @Test func savingNothingClosesTheSheetWithoutARequest() async throws {
  let writes = Mutex(0)
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return list(account()) }
    writes.withLock { $0 += 1 }
    return one(account())
  }, test: { client in
    let board = GitHubAccountBoard()
    try await loaded(board, client: client)
    board.edit(try #require(board.accounts.first), client: client)
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    try await Task.sleep(for: .milliseconds(30))
    #expect(writes.withLock { $0 } == 0)
    try await stop(board)
  })
}

@MainActor @Test func removingAppliesAtOnceAndComesBackOnFailure() async throws {
  let refuse = Mutex(true)
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return refuse.withLock { $0 } ? list(account()) : list() }
    return refuse.withLock { $0 }
      ? refused(500, "Could not remove", delay: 0.05) : StubResponse(status: 204, body: Data(), delay: 0.05)
  }, test: { client in
    let board = GitHubAccountBoard()
    try await loaded(board, client: client)
    let saved = try #require(board.accounts.first)
    board.remove(saved, client: client)
    #expect(board.accounts.isEmpty)
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(20))
    #expect(board.accounts.isEmpty)
    try await wait { !board.accounts.isEmpty }
    #expect(board.errors[saved.id] != nil)

    refuse.withLock { $0 = false }
    board.remove(saved, client: client)
    #expect(board.errors[saved.id] == nil)
    try await Task.sleep(for: .milliseconds(120))
    #expect(board.accounts.isEmpty)
    try await stop(board)
  })
}

@MainActor @Test func resetDropsAnAnswerFromTheOldConnection() async throws {
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    return isList(request) ? list() : one(account(), delay: 0.05)
  }, test: { client in
    let board = GitHubAccountBoard()
    board.startNew(client: client)
    board.draft?.token.value = typed
    board.saveDraft(client: client)
    board.reset()
    #expect(board.draft == nil)
    #expect(!board.isSaving)
    try await Task.sleep(for: .milliseconds(120))
    #expect(board.accounts.isEmpty)
    #expect(board.draft == nil)
  })
}
