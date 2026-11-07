import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let made = "2026-11-05T10:00:00Z"
private let typed = "made-up-value"

private func credential(_ name: String = "ACME_TOKEN", github: Bool = false) -> String {
  let secret = github ? "null" : #"{"configured":true,"passwordManager":null,"reference":null}"#
  return #"{"name":"\#(name)","hosts":["api.example.com"],"secret":\#(secret),"createdAt":"\#(made)","#
    + #""updatedAt":"\#(made)","lastUsedAt":null,"lastError":null,"github":\#(github)}"#
}

private let waitingRequest = #"{"name":"ACME_TOKEN","hosts":["api.example.com","*.example.com"],"#
  + #""reason":"Deploying","requestedAt":"\#(made)"}"#

private func credentials(items: [String] = [], requests: [String] = []) -> StubResponse {
  let items = items.joined(separator: ",")
  let requests = requests.joined(separator: ",")
  return StubResponse(body: Data(#"{"credentials":[\#(items)],"requests":[\#(requests)]}"#.utf8))
}

private let login = #"{"name":"github","hosts":["github.com"],"fields":{"#
  + #""username":{"configured":true,"passwordManager":"1password","reference":"op://v/i/username"},"#
  + #""password":{"configured":true,"passwordManager":null,"reference":null},"#
  + #""one_time_code":{"configured":true,"passwordManager":null,"reference":null}},"#
  + #""createdAt":"\#(made)","updatedAt":"\#(made)","lastUsedAt":null,"lastError":null}"#

private func refused(_ status: Int, _ message: String) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8))
}

private let managers = StubResponse(body: Data(
  (#"{"passwordManagers":[{"id":"1password","name":"1Password","connected":true,"connectedAt":null,"#
    + #""usedBy":[]},{"id":"bitwarden","name":"Bitwarden","connected":false,"connectedAt":null,"#
    + #""usedBy":[]}]}"#).utf8))

private func ask(_ kind: BotSecretKind = .credential, isError: Bool? = nil, at requestedAt: String = made) -> Message {
  Message(
    id: "m1", role: "toolResult", toolName: kind.toolName, isError: isError,
    toolDetails: .object([
      "name": .string(kind == .credential ? "ACME_TOKEN" : "github"), "hosts": .array([.string("api.example.com")]),
      "requestedAt": .string(requestedAt)
    ]))
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

/// The read that follows a write must land before the test's stub goes away.
@MainActor
private func stop(_ board: BotSecretBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(300))
}

private func isPUT(_ request: URLRequest) -> Bool { request.httpMethod == "PUT" }

private func body(_ request: URLRequest) throws -> [String: JSONValue] {
  guard case .object(let object) = try requestJSON(request) else { throw URLError(.cannotDecodeRawData) }
  return object
}

private func field(_ value: JSONValue?, _ key: String) -> JSONValue? {
  if case .object(let object)? = value { object[key] } else { nil }
}

@Test func aRequestToolResultSaysWhatWasAsked() throws {
  let asked = try #require(BotSecretAsk(message: ask()))
  #expect(asked.kind == .credential)
  #expect(asked.name == "ACME_TOKEN")
  #expect(asked.hosts == ["api.example.com"])
  #expect(asked.requestedAt == made)
  #expect(BotSecretAsk(message: ask(.login))?.kind == .login)
  #expect(BotSecretAsk(message: ask(isError: true)) == nil)
  var other = ask()
  other.toolName = "memory"
  #expect(BotSecretAsk(message: other) == nil)
}

@Test func theDraftFollowsTheNameRulesAndNeedsHostsAndAValue() {
  var draft = BotSecretDraft(kind: .credential, agentID: "a1")
  draft.name = "acme_token"
  #expect(draft.name == "ACME_TOKEN")
  #expect(draft.nameIsValid)
  #expect(!draft.isReady)
  draft.hosts = "API.example.com, *.example.com other.example"
  #expect(draft.hostList == ["api.example.com", "*.example.com", "other.example"])
  #expect(!draft.isReady)
  draft.value.value = typed
  #expect(draft.isReady)
  draft.name = "1BAD"
  #expect(!draft.isReady)

  var login = BotSecretDraft(kind: .login, agentID: "a1")
  login.name = "GitHub"
  #expect(login.name == "github")
  login.hosts = "github.com"
  login.username.value = typed
  #expect(!login.isReady)
  login.password.value = typed
  #expect(login.isReady)
  login.hasCode = true
  #expect(!login.isReady)
  login.oneTimeCode.value = typed
  #expect(login.isReady)
  login.usesItem = true
  login.item = "op://vault/item/field"
  #expect(!login.isReady)
  login.item = " op://vault/item "
  #expect(login.isReady)
}

@Test func aRequestFillsTheDraftAndAPicksSourceDropsTheOtherOne() {
  let proposed = BotSecretRequest(
    name: "github", hosts: ["github.com"], reason: "Signing in", oneTimeCode: true, requestedAt: made)
  var draft = BotSecretDraft(kind: .login, agentID: "a1", request: proposed)
  #expect(draft.name == "github")
  #expect(draft.nameLocked)
  #expect(draft.hasCode)
  draft.password.value = typed
  draft.password.use(.onePassword)
  #expect(draft.password.value.isEmpty)
  #expect(draft.password.input == nil)
}

@Test func aDraftNeverPrintsWhatWasTyped() {
  var draft = BotSecretDraft(kind: .credential, agentID: "a1")
  draft.value.value = typed
  var dumped = ""
  dump(draft, to: &dumped)
  #expect(!dumped.contains(typed))
  #expect(!String(describing: draft).contains(typed))
  #expect(!String(reflecting: draft.value).contains(typed))
}

@MainActor @Test func listsDecodeWithoutValues() async throws {
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/logins") == true {
      return StubResponse(body: Data(#"{"logins":[\#(login)],"requests":[]}"#.utf8))
    }
    return credentials(items: [credential(), credential("GH_TOKEN", github: true)], requests: [waitingRequest])
  }, test: { client in
    let creds = try await client.botSecrets(.credential, agentID: "a1")
    #expect(creds.items.map(\.name) == ["ACME_TOKEN", "GH_TOKEN"])
    #expect(creds.items[0].secret?.configured == true)
    #expect(creds.items[1].managed)
    #expect(creds.items[1].secret == nil)
    #expect(creds.requests.first?.reason == "Deploying")
    let logins = try await client.botSecrets(.login, agentID: "a1")
    #expect(logins.items[0].username == SecretStatus(
      configured: true, passwordManager: .onePassword, reference: "op://v/i/username"))
    #expect(logins.items[0].oneTimeCode?.configured == true)
  })
}

@MainActor @Test func aCardWaitsThenSettles() async throws {
  let saved = Mutex(false)
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    if isPUT(request) {
      saved.withLock { $0 = true }
      return StubResponse(body: Data(credential().utf8))
    }
    return saved.withLock { $0 } ? credentials(items: [credential()]) : credentials(requests: [waitingRequest])
  }, test: { client in
    let board = BotSecretBoard()
    board.select("a1")
    let asked = try #require(BotSecretAsk(message: ask()))
    #expect(board.state(of: asked) == .outcome("Loading…"))
    board.refreshIfChanged(messages: [ask()], client: client)
    #expect(board.needsPolling)
    try await wait { board.state(of: asked) != .outcome("Loading…") }
    guard case .waiting(let waiting) = board.state(of: asked) else { throw URLError(.badServerResponse) }

    board.add(waiting, kind: .credential, agentID: "a1", client: client)
    #expect(board.draft?.nameLocked == true)
    try await wait { !board.connectedManagers.isEmpty }
    #expect(board.connectedManagers.map(\.id) == [.onePassword])
    board.draft?.value.value = typed
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(board.state(of: asked) == .outcome("Saved"))
    #expect(!board.needsPolling)
    try await stop(board)
  })
}

@MainActor @Test func aStaleRequestInTheListDoesNotMatchANewAsk() async throws {
  try await withClient(handler: { _ in credentials(requests: [waitingRequest]) }, test: { client in
    let board = BotSecretBoard()
    board.select("a1")
    let later = ask(at: "2026-11-06T10:00:00Z")
    board.refreshIfChanged(messages: [later], client: client)
    let asked = try #require(BotSecretAsk(message: later))
    try await wait { board.state(of: asked) != .outcome("Loading…") }
    #expect(board.state(of: asked) == .outcome("Declined"))
    try await stop(board)
  })
}

@MainActor @Test func aFailedReadIsUnavailable() async throws {
  try await withClient(handler: { _ in refused(500, "Down") }, test: { client in
    let board = BotSecretBoard()
    board.select("a1")
    board.refreshIfChanged(messages: [ask()], client: client)
    let asked = try #require(BotSecretAsk(message: ask()))
    try await wait { board.state(of: asked) == .outcome("Unavailable") }
    #expect(board.needsPolling)
    #expect(board.readError(.credential, agentID: "a1") == "Down")
    try await stop(board)
  })
}

@MainActor
private func ready(_ board: BotSecretBoard, name: String = "ACME_TOKEN", client: APIClient) {
  board.startNew(.credential, agentID: "a1", client: client)
  board.draft?.name = name
  board.draft?.hosts = "api.example.com"
  board.draft?.value.value = typed
}

@MainActor @Test func aPlainSaveShowsAtOnceAndSurvivesARead() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    if isPUT(request) { return StubResponse(body: Data(credential().utf8), delay: 0.1) }
    let read = reads.withLock { $0 += 1; return $0 }
    return read < 3 ? credentials(requests: [waitingRequest]) : credentials(items: [credential()])
  }, test: { client in
    let board = BotSecretBoard()
    board.refresh(.credential, agentID: "a1", client: client)
    try await wait { !board.requests(.credential, agentID: "a1").isEmpty }
    let target = BotSecretTarget(kind: .credential, agentID: "a1", name: "ACME_TOKEN")

    ready(board, client: client)
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(!board.isSaving)
    #expect(board.isUnconfirmed(target))
    #expect(board.items(.credential, agentID: "a1").map(\.hosts) == [["api.example.com"]])
    #expect(board.requests(.credential, agentID: "a1").isEmpty)

    let row = try #require(board.items(.credential, agentID: "a1").first)
    board.edit(row, agentID: "a1", client: client)
    board.delete(row, agentID: "a1", client: client)
    #expect(board.draft == nil)

    board.refresh(.credential, agentID: "a1", client: client)
    try await Task.sleep(for: .milliseconds(40))
    #expect(board.items(.credential, agentID: "a1").count == 1)

    try await wait { !board.isUnconfirmed(target) }
    #expect(board.items(.credential, agentID: "a1").first?.secret?.configured == true)
    try await stop(board)
  })
}

@MainActor @Test func aFailedSaveGivesTheSheetBackWithWhatWasTyped() async throws {
  let bodies = Mutex<[[String: JSONValue]]>([])
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    if isPUT(request) {
      let sent = try body(request)
      let count = bodies.withLock { $0.append(sent); return $0.count }
      return count == 1 ? refused(400, "Hosts are invalid") : StubResponse(body: Data(credential().utf8))
    }
    return credentials(items: bodies.withLock { $0.count } > 1 ? [credential()] : [], requests: [waitingRequest])
  }, test: { client in
    let board = BotSecretBoard()
    board.refresh(.credential, agentID: "a1", client: client)
    try await wait { !board.requests(.credential, agentID: "a1").isEmpty }
    ready(board, client: client)
    let id = board.draft?.id
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(!board.items(.credential, agentID: "a1").isEmpty)
    try await wait { !board.saveError.isEmpty }
    #expect(board.saveError == "Hosts are invalid")
    #expect(board.draft?.id == id)
    #expect(board.draft?.value.value == typed)
    #expect(board.items(.credential, agentID: "a1").isEmpty)
    #expect(board.requests(.credential, agentID: "a1").map(\.name) == ["ACME_TOKEN"])
    #expect(field(bodies.withLock { $0[0]["secret"] }, "value") == .string(typed))

    board.saveDraft(client: client)
    #expect(board.saveError.isEmpty)
    #expect(board.draft == nil)
    try await wait { bodies.withLock { $0.count } == 2 }
    #expect(board.items(.credential, agentID: "a1").map(\.name) == ["ACME_TOKEN"])
    try await stop(board)
  })
}

@MainActor @Test func aFailedSaveWaitsForTheOpenSheetToClose() async throws {
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    if isPUT(request) { return StubResponse(status: 400, body: refused(400, "No").body, delay: 0.05) }
    return credentials()
  }, test: { client in
    let board = BotSecretBoard()
    let target = BotSecretTarget(kind: .credential, agentID: "a1", name: "ACME_TOKEN")
    ready(board, client: client)
    let failed = board.draft?.id
    board.saveDraft(client: client)
    ready(board, name: "OTHER_TOKEN", client: client)
    let next = board.draft?.id
    try await wait { !board.isUnconfirmed(target) }
    #expect(board.draft?.id == next)
    #expect(board.draft?.value.value == typed)
    #expect(board.saveError.isEmpty)

    board.closeDraft()
    #expect(board.draft?.id == failed)
    #expect(board.draft?.value.value == typed)
    #expect(board.saveError == "No")

    board.closeDraft()
    #expect(board.draft == nil)
    #expect(board.saveError.isEmpty)
    try await stop(board)
  })
}

@MainActor @Test func aReferenceHoldsTheSheetUntilTheServerAnswers() async throws {
  let puts = Mutex(0)
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    if isPUT(request) {
      let count = puts.withLock { $0 += 1; return $0 }
      return count == 1
        ? StubResponse(status: 400, body: refused(400, "Can't read it").body, delay: 0.05)
        : StubResponse(body: Data(credential().utf8), delay: 0.05)
    }
    return credentials(items: puts.withLock { $0 } > 1 ? [credential()] : [])
  }, test: { client in
    let board = BotSecretBoard()
    ready(board, client: client)
    board.draft?.value.use(.onePassword)
    board.draft?.value.reference = "op://vault/item/field"
    let id = board.draft?.id
    board.saveDraft(client: client)
    #expect(board.isSaving)
    #expect(!board.canSave)
    #expect(board.items(.credential, agentID: "a1").isEmpty)

    board.closeDraft()
    board.startNew(.login, agentID: "a1", client: client)
    #expect(board.draft?.id == id)
    #expect(board.draft?.value.reference == "op://vault/item/field")

    try await wait { !board.isSaving }
    #expect(board.saveError == "Can't read it")
    #expect(board.draft?.value.reference == "op://vault/item/field")
    #expect(board.canSave)

    board.saveDraft(client: client)
    #expect(board.isSaving)
    try await wait { board.draft == nil }
    #expect(!board.isSaving)
    #expect(board.items(.credential, agentID: "a1").map(\.name) == ["ACME_TOKEN"])
    try await stop(board)
  })
}

@Test func onlyANewReferenceDependsOnAPasswordManager() {
  var credential = BotSecretDraft(kind: .credential, agentID: "a1")
  credential.value.value = typed
  #expect(!credential.checksPasswordManager)
  credential.value.use(.bitwarden)
  credential.value.reference = "made-up-id"
  #expect(credential.checksPasswordManager)

  var saved = BotSecret(kind: .login, name: "github", hosts: ["github.com"])
  saved.username = SecretStatus(configured: true, passwordManager: .onePassword, reference: "op://v/i/username")
  saved.password = SecretStatus(configured: true)
  var login = BotSecretDraft(kind: .login, agentID: "a1", existing: saved)
  login.hosts = "github.com, *.github.com"
  #expect(!login.checksPasswordManager)
  login.password.value = typed
  #expect(!login.checksPasswordManager)
  login.username.reference = "op://v/other/username"
  #expect(login.checksPasswordManager)

  var item = BotSecretDraft(kind: .login, agentID: "a1", existing: saved)
  item.usesItem = true
  #expect(item.checksPasswordManager)
}

@MainActor @Test func savingTheOtherFieldsLeavesSavedSecretsAlone() async throws {
  let sent = Mutex<[String: JSONValue]>([:])
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    if isPUT(request) {
      let saved = try body(request)
      sent.withLock { $0 = saved }
      return StubResponse(body: Data(login.utf8))
    }
    return StubResponse(body: Data(#"{"logins":[\#(login)],"requests":[]}"#.utf8))
  }, test: { client in
    let board = BotSecretBoard()
    board.refresh(.login, agentID: "a1", client: client)
    try await wait { board.isLoaded(.login, agentID: "a1") }
    let saved = try #require(board.items(.login, agentID: "a1").first)
    board.edit(saved, agentID: "a1", client: client)
    #expect(board.draft?.username.manager == .onePassword)
    #expect(board.draft?.username.reference == "op://v/i/username")
    #expect(board.draft?.password.keepPlaceholder == "Keep the saved value")
    #expect(board.draft?.hasCode == true)
    board.draft?.hosts = "github.com, *.github.com"
    board.draft?.hasCode = false
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    let target = BotSecretTarget(kind: .login, agentID: "a1", name: "github")
    try await wait { !board.isUnconfirmed(target) }
    let fields = sent.withLock { $0["fields"] }
    #expect(fields == .object(["one_time_code": .null]))
    #expect(sent.withLock { $0["hosts"] } == .array([.string("github.com"), .string("*.github.com")]))
    try await stop(board)
  })
}

@MainActor @Test func deletingHidesTheRowAndAFailureBringsItBack() async throws {
  let allow = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "DELETE" {
      return allow.withLock { $0 }
        ? StubResponse(status: 204, body: Data())
        : refused(500, "No")
    }
    return credentials(items: allow.withLock { $0 } ? [] : [credential()])
  }, test: { client in
    let board = BotSecretBoard()
    board.refresh(.credential, agentID: "a1", client: client)
    try await wait { !board.items(.credential, agentID: "a1").isEmpty }
    let item = try #require(board.items(.credential, agentID: "a1").first)
    let target = BotSecretTarget(kind: .credential, agentID: "a1", name: item.name)

    board.delete(item, agentID: "a1", client: client)
    #expect(board.items(.credential, agentID: "a1").isEmpty)
    try await wait { board.errors[target] != nil }
    try await wait { !board.items(.credential, agentID: "a1").isEmpty }
    #expect(board.errors[target] == "No")

    allow.withLock { $0 = true }
    board.delete(item, agentID: "a1", client: client)
    #expect(board.errors[target] == nil)
    #expect(board.items(.credential, agentID: "a1").isEmpty)
    try await Task.sleep(for: .milliseconds(40))
    #expect(board.items(.credential, agentID: "a1").isEmpty)
    #expect(board.isLoaded(.credential, agentID: "a1"))
    try await stop(board)
  })
}

@MainActor @Test func aManagedTokenStaysAsItIs() async throws {
  let writes = Mutex(0)
  try await withClient(handler: { request in
    if request.httpMethod != "GET" { writes.withLock { $0 += 1 } }
    return credentials(items: [credential("GH_TOKEN", github: true)])
  }, test: { client in
    let board = BotSecretBoard()
    board.refresh(.credential, agentID: "a1", client: client)
    try await wait { board.isLoaded(.credential, agentID: "a1") }
    let item = try #require(board.items(.credential, agentID: "a1").first)
    board.edit(item, agentID: "a1", client: client)
    board.delete(item, agentID: "a1", client: client)
    #expect(board.draft == nil)
    #expect(board.items(.credential, agentID: "a1").count == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(writes.withLock { $0 } == 0)
    try await stop(board)
  })
}

@MainActor @Test func decliningPostsAndWaitsForTheServer() async throws {
  let declined = Mutex(0)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      #expect(request.url?.path.hasSuffix("/credentials/ACME_TOKEN/decline") == true)
      let count = declined.withLock { $0 += 1; return $0 }
      return count == 1 ? refused(500, "No") : StubResponse(status: 204, body: Data())
    }
    return credentials(requests: declined.withLock { $0 } < 2 ? [waitingRequest] : [])
  }, test: { client in
    let board = BotSecretBoard()
    board.select("a1")
    board.refreshIfChanged(messages: [ask()], client: client)
    let asked = try #require(BotSecretAsk(message: ask()))
    try await wait { !board.requests(.credential, agentID: "a1").isEmpty }
    let waiting = try #require(board.requests(.credential, agentID: "a1").first)
    let target = BotSecretTarget(kind: .credential, agentID: "a1", name: waiting.name)

    board.decline(waiting, kind: .credential, agentID: "a1", client: client)
    #expect(board.declining.contains(target))
    #expect(board.state(of: asked) == .waiting(waiting))
    try await wait { board.errors[target] == "No" }
    #expect(!board.declining.contains(target))
    #expect(board.state(of: asked) == .waiting(waiting))

    board.decline(waiting, kind: .credential, agentID: "a1", client: client)
    try await wait { board.state(of: asked) == .outcome("Declined") }
    try await stop(board)
  })
}

@MainActor @Test func aResultAfterTheConnectionChangedIsDropped() async throws {
  try await withClient(handler: { request in
    if request.url?.path.hasSuffix("/password-managers") == true { return managers }
    return StubResponse(body: credentials(items: [credential()]).body, delay: 0.02)
  }, test: { client in
    let board = BotSecretBoard()
    board.refresh(.credential, agentID: "a1", client: client)
    try await stop(board)
    #expect(!board.isLoaded(.credential, agentID: "a1"))
  })
}

@MainActor @Test func usesLoadAPageAtATimeUntilTheyRunOut() async throws {
  let queries = Mutex<[String]>([])
  try await withClient(handler: { request in
    queries.withLock { $0.append(request.url?.query ?? "") }
    let first = queries.withLock { $0.count } == 1
    let rows = first ? ["u2", "u1"] : ["u0"]
    let uses = rows.map {
      #"{"id":"\#($0)","at":"\#(made)","method":"GET","host":"api.example.com","path":"/v1","#
        + #""status":\#($0 == "u0" ? "null" : "200"),"error":\#($0 == "u0" ? "\"Locked\"" : "null")}"#
    }
    return StubResponse(body: Data(("[" + uses.joined(separator: ",") + "]").utf8))
  }, test: { client in
    let log = BotSecretUseLog(
      target: BotSecretTarget(kind: .credential, agentID: "a1", name: "ACME_TOKEN"), pageSize: 2)
    log.loadMore(client: client)
    try await wait { log.uses.count == 2 }
    #expect(log.hasMore)
    #expect(log.uses[0].summary == "GET api.example.com/v1")
    #expect(log.uses[0].outcome == "200")
    log.loadMore(client: client)
    try await wait { log.uses.count == 3 }
    #expect(!log.hasMore)
    #expect(log.uses[2].failed)
    #expect(log.uses[2].outcome == "Locked")
    #expect(queries.withLock { $0.last }?.contains("before=u1") == true)
  })
}

@Test func theLastUseSaysWhatHappened() throws {
  var item = BotSecret(kind: .login, name: "github", hosts: [])
  #expect(item.lastUse() == "Never filled")
  item.lastUsedAt = made
  let day = try #require(automationRunDate(made)?.addingTimeInterval(86400))
  #expect(item.lastUse(now: day) == "Filled yesterday")
  item.lastError = "Locked"
  #expect(item.lastUse() == "Locked")
}
