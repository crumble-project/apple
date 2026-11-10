import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

@Test func reservedCredentialNamesCannotBeAdded() {
  var draft = BotSecretDraft(kind: .credential, agentID: "a1")
  draft.hosts = "api.example.com"
  draft.value.value = "made-up"
  draft.name = "ACME_TOKEN"
  #expect(draft.isReady)
  #expect(draft.nameError == nil)
  for name in ["PATH", "ssl_cert_file", "CRUMBLE_ANYTHING", "GIT_CONFIG_COUNT", "NODE_USE_ENV_PROXY"] {
    draft.name = name
    #expect(!draft.isReady, "\(name)")
    #expect(draft.nameError != nil, "\(name)")
  }
  var login = BotSecretDraft(kind: .login, agentID: "a1")
  login.name = "path"
  #expect(login.nameIsValid)
  #expect(login.nameError == nil)
}

private func entry(_ id: String) -> String {
  #"{"id":"\#(id)","kind":"tool-call","agentId":"a1","agentName":"Atlas","entryId":"e","#
    + #""timestamp":1700000000000,"details":{"toolName":"read"}}"#
}

private func feed(_ ids: [String], next: String? = nil) -> StubResponse {
  let cursor = next.map { #"\#"\#($0)\#""# } ?? "null"
  return json(
    #"{"activities":[\#(ids.map(entry).joined(separator: ","))],"hasMore":\#(next != nil),"nextCursor":\#(cursor)}"#)
}

@Test @MainActor func theActivityFeedFiltersAndPagesWithTheServersCursor() async throws {
  let seen = Mutex<[String]>([])
  try await withClient(handler: { request in
    let query = request.url?.query ?? ""
    seen.withLock { $0.append(query) }
    if query.contains("cursor=c1") { return feed(["3", "2"]) }
    if query.contains("kind=mcp-call") { return feed(["9"]) }
    // A short page can still have more.
    return feed(["1", "2"], next: "c1")
  }, test: { client in
    let board = ActivityBoard(pageSize: 50)
    board.refresh(client: client)
    try await wait { board.isLoaded }
    #expect(board.hasMore)

    board.loadMore(client: client)
    try await wait { !board.hasMore }
    #expect(board.entries.map(\.id) == ["1", "2", "3"])

    board.show(kind: .mcpCall, botID: "a1", client: client)
    #expect(board.entries.isEmpty)
    try await wait { board.isLoaded }
    #expect(board.entries.map(\.id) == ["9"])
    #expect(board.emptyText == "Nothing of this kind yet.")
    let last = try #require(seen.withLock { $0.last })
    #expect(last.contains("kind=mcp-call") && last.contains("agentId=a1") && last.contains("limit=50"))
  })
}

@Test @MainActor func aLatePageNeverLandsOnANewFilter() async throws {
  try await withClient(handler: { request in
    let query = request.url?.query ?? ""
    return query.contains("kind=change") ? feed(["new"]) : StubResponse(body: feed(["old"]).body, delay: 0.1)
  }, test: { client in
    let board = ActivityBoard()
    board.refresh(client: client)
    board.show(kind: .change, botID: nil, client: client)
    try await wait { board.isLoaded }
    try await Task.sleep(for: .milliseconds(200))
    #expect(board.entries.map(\.id) == ["new"])
  })
}

@Test @MainActor func aDeletedBotsFilterFallsBackToEveryBot() async throws {
  try await withClient(handler: { request in
    (request.url?.query ?? "").contains("agentId")
      ? json(#"{"error":"Not found"}"#, status: 404) : feed(["1"])
  }, test: { client in
    let board = ActivityBoard()
    board.show(kind: nil, botID: "gone", client: client)
    try await wait { board.isLoaded }
    #expect(board.botID == nil)
    #expect(board.readError == nil)
  })
}

@MainActor final class AvatarStubHost: BotListHost {
  var agents: [Agent]
  var pending: Set<String> = []
  var errorText = ""
  let client: APIClient

  init(_ bot: Agent, client: APIClient) {
    agents = [bot]
    self.client = client
  }

  func optimisticMutation(
    key: String,
    update: () -> Void,
    rollback: @escaping @MainActor () -> Void,
    work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  ) {
    pending.insert(key)
    update()
    Task {
      do {
        let confirm = try await work(client)
        pending.remove(key)
        confirm?()
      } catch {
        pending.remove(key)
        rollback()
        errorText = friendlyError(error)
      }
    }
  }
}

@Test @MainActor func anAvatarShowsAtOnceAndRollsBackOnFailure() async throws {
  try await withClient(handler: { _ in json(#"{"error":"Nope"}"#, status: 500, delay: 0.02) }, test: { client in
    let bot = Agent(id: "a1", name: "Atlas")
    let host = AvatarStubHost(bot, client: client)
    let board = AvatarBoard()
    board.select(bot)
    var edited = board.value
    edited.color = "#112233"
    board.value = edited
    board.save(to: host)
    #expect(host.agents[0].avatar.color == "#112233")
    #expect(host.pending == ["avatar:a1"])
    #expect(!board.canSave)
    try await wait { !board.isSaving }
    #expect(host.agents[0].avatar.color == bot.avatar.color)
    #expect(host.pending.isEmpty)
    #expect(host.errorText.isEmpty)
    #expect(board.value.color == "#112233")
    #expect(!board.saveError.isEmpty)
    #expect(!board.saved)
  })
}

private func agentJSON(_ bot: Agent) throws -> String {
  let avatar = try #require(String(data: JSONEncoder().encode(bot.avatar), encoding: .utf8))
  return #"{"id":"\#(bot.id)","name":"\#(bot.name)","avatar":\#(avatar),"description":"","instructions":"","#
    + #""provider":"openai","model":"gpt","enabled":true,"tools":[],"skills":[],"mcpServers":[],"delegates":[],"#
    + #""createdAt":"2026-11-05T10:00:00.000Z","updatedAt":"2026-11-05T10:00:00.000Z"}"#
}

@Test @MainActor func onlyAConfirmedAvatarSaysSavedAndLaterEditsSurvive() async throws {
  let bot = Agent(id: "a1", name: "Atlas")
  try await withClient(handler: { _ in json(try agentJSON(bot), delay: 0.05) }, test: { client in
    let host = AvatarStubHost(bot, client: client)
    let board = AvatarBoard()
    #expect(!board.canSave)
    board.select(bot)
    board.save(to: host)
    #expect(!board.saved)
    var newer = board.value
    newer.color = "#445566"
    board.value = newer
    try await wait { !board.isSaving }
    #expect(board.value.color == "#445566")
    #expect(!board.saved)

    board.save(to: host)
    try await wait { !board.isSaving }
    #expect(board.saved)
  })
}

@Test @MainActor func aDeletedBotLeavesTheAvatarPageInPreview() {
  let bot = Agent(id: "a1", name: "Atlas")
  let board = AvatarBoard()
  board.select(bot)
  board.keepSelection(in: ["a1", "a2"])
  #expect(board.canSave)

  board.keepSelection(in: ["a2"])
  #expect(board.botID.isEmpty)
  #expect(!board.canSave)
}
