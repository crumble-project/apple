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

private func credential(_ name: String, host: String) -> String {
  #"{"name":"\#(name)","hosts":["\#(host)"],"secret":{"configured":true},"lastUsedAt":null,"#
    + #""lastError":null,"github":false,"createdAt":"2026-11-05T10:00:00.000Z","#
    + #""updatedAt":"2026-11-05T10:00:00.000Z"}"#
}

private func list(_ items: [String], requests: [String] = []) -> StubResponse {
  json(#"{"credentials":[\#(items.joined(separator: ","))],"requests":[\#(requests.joined(separator: ","))]}"#)
}

private let wanted = #"{"name":"WANTED","hosts":["want.example.com"],"reason":"For a job","#
  + #""requestedAt":"2026-11-05T10:00:00.000Z"}"#

private func bots() -> [Agent] {
  [Agent(id: "a1", name: "Atlas"), Agent(id: "a2", name: "Juniper"), Agent(id: "a3", name: "Pixel")]
}

@Test @MainActor func aPageNarrowsByBotAndSearchAsTheWebDoes() async throws {
  try await withClient(handler: { request in
    let path = request.url?.path ?? ""
    if path.contains("/a1/") { return list([credential("ACME_TOKEN", host: "api.acme.com")]) }
    if path.contains("/a2/") {
      return list([credential("OTHER", host: "other.example.com")], requests: [wanted])
    }
    return list([])
  }, test: { client in
    let board = BotSecretBoard()
    for bot in bots() { board.refresh(.credential, agentID: bot.id, client: client) }
    try await wait { bots().allSatisfy { board.isLoaded(.credential, agentID: $0.id) } }

    let all = board.page(.credential, bots: bots(), scope: nil, search: "")
    #expect(all.total == 3)
    #expect(all.counts == ["a1": 1, "a2": 2, "a3": 0])
    #expect(all.waiting.map(\.request.name) == ["WANTED"])
    // Every bot in scope leaves out a bot with nothing to show.
    #expect(all.groups.map(\.bot.id) == ["a1", "a2"])

    let host = board.page(.credential, bots: bots(), scope: nil, search: "  API.acme ")
    #expect(host.groups.map(\.bot.id) == ["a1"])
    #expect(host.waiting.isEmpty)

    let one = board.page(.credential, bots: bots(), scope: "a2", search: "acme")
    #expect(one.groups.map(\.note) == [BotSecretKind.credential.noMatchText])

    let empty = board.page(.credential, bots: bots(), scope: "a3", search: "")
    #expect(empty.groups.map(\.note) == [BotSecretKind.credential.emptyText])

    let none = board.page(.credential, bots: bots(), scope: nil, search: "nothing")
    #expect(none.groups.isEmpty)
    #expect(none.note == BotSecretKind.credential.noMatchText)

    #expect(board.page(.credential, bots: bots(), scope: "gone", search: "").scope == nil)
  })
}

@Test @MainActor func aNewSecretFromAPageAsksWhichBot() async throws {
  try await withClient(handler: { _ in json(#"{"passwordManagers":[]}"#) }, test: { client in
    let board = BotSecretBoard()
    board.startNew(.login, choosingFrom: bots(), client: client)
    #expect(board.draft?.choosesBot == true)
    #expect(board.draft?.agentID == "a1")
    board.draft?.agentID = "a2"
    #expect(board.draft?.agentID == "a2")
    board.closeDraft()
    board.startNew(.login, agentID: "a3", client: client)
    #expect(board.draft?.choosesBot == false)
  })
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

@Test @MainActor func aGatewayDraftResetsWithoutClosingItsSheet() async throws {
  let board = MessageGatewayBoard()
  let gateway = MessageGateway(
    id: "discord", label: "Discord", secretKey: "k", tokenConfigured: true,
    config: GatewayConfig(ownerID: "1", allowedChannelIDs: ["c1"]), status: .connected)
  board.edit(gateway)
  let sheet = board.draft?.id
  board.draft?.ownerID = "2"
  board.draft?.channels = []
  #expect(board.draft?.isDirty == true)
  board.resetDraft()
  #expect(board.draft?.id == sheet)
  #expect(board.draft?.isDirty == false)
  #expect(board.draft?.channels.map(\.value) == ["c1"])
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

private func providerStatus(_ apiKey: SecretStatus = SecretStatus(configured: false)) -> ProviderStatus {
  ProviderStatus(provider: "openai", configured: apiKey.configured, apiKey: apiKey)
}

@Test @MainActor func aProviderKeyClearsAtOnceAndComesBackOnFailure() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(#"{"error":"Nope"}"#, status: 400, delay: 0.05)
  }, test: { client in
    let board = ProviderKeyBoard()
    board.show(provider: "openai", status: providerStatus())
    board.source.value = "  made-up  "
    board.save(client: client) {}
    #expect(board.source.value.isEmpty)
    #expect(board.isSaving)
    try await wait { !board.isSaving }
    #expect(board.source.value == "  made-up  ")
    #expect(!board.saveError.isEmpty)
    let body = try #require(bodies.withLock { $0.first })
    #expect(body == .object(["value": .string("made-up")]))
  })
}

@Test @MainActor func aProviderReferenceWaitsForTheServerAndIsSentAsAReference() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(#"{"provider":"openai","configured":true}"#, delay: 0.05)
  }, test: { client in
    let board = ProviderKeyBoard()
    board.show(provider: "openai", status: providerStatus())
    board.source.use(.onePassword)
    #expect(!board.canSave)
    board.source.reference = "op://vault/item/field"
    var finished = false
    board.save(client: client) { finished = true }
    #expect(board.source.reference == "op://vault/item/field")
    try await wait { finished }
    #expect(!board.canSave)
    let body = try #require(bodies.withLock { $0.first })
    #expect(body == .object([
      "reference": .object(["passwordManager": .string("1password"), "reference": .string("op://vault/item/field")])
    ]))
  })
}

@Test @MainActor func aSavedReferenceFillsTheFormAndSurvivesARefreshWithTypedText() {
  let board = ProviderKeyBoard()
  let saved = SecretStatus(configured: true, passwordManager: .bitwarden, reference: "id")
  board.show(provider: "openai", status: providerStatus(saved))
  #expect(board.source.manager == .bitwarden)
  #expect(!board.canSave)

  board.source.reference = "other"
  board.show(provider: "openai", status: providerStatus())
  #expect(board.source.reference == "other")

  board.show(provider: "groq", status: nil)
  #expect(board.source.manager == nil)
  #expect(providerStatus(saved).savedLabel(managers: []) == nil)
  var keyed = providerStatus(saved)
  keyed.credentialType = .apiKey
  #expect(keyed.savedLabel(managers: [PasswordManager(id: .bitwarden, name: "Bitwarden", connected: true)])
    == "API key in Bitwarden")
}

@Test func anMCPDraftSendsAReferenceOnlyWhenItChanged() {
  var draft = MCPDraft(server: MCPServer(
    id: "m1", name: "Docs", url: "https://example.com", enabled: true, auth: "token",
    token: SecretStatus(configured: true, passwordManager: .onePassword, reference: "op://a/b/c")))
  #expect(draft.token.manager == .onePassword)
  #expect(draft.payload(name: "Docs", url: "https://example.com")["token"] == nil)
  #expect(!draft.checksPasswordManager)

  draft.token.reference = "op://a/b/d"
  #expect(draft.checksPasswordManager)
  #expect(draft.payload(name: "Docs", url: "https://example.com")["token"] == .object([
    "reference": .object(["passwordManager": .string("1password"), "reference": .string("op://a/b/d")])
  ]))

  var typed = MCPDraft(serverID: "")
  typed.token.value = "made-up"
  #expect(typed.tokenPlaceholder == "Optional")
  #expect(typed.payload(name: "A", url: "https://a.example")["token"] == .object(["value": .string("made-up")]))
}

@MainActor private final class AvatarStubHost: AvatarHost {
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
