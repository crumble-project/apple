import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let made = "2026-11-05T10:00:00Z"
private let commit = String(repeating: "a", count: 40)
private let origin = #"{"repository":"acme/skills","branch":"main","path":"lint","commit":"\#(commit)","digest":"d"}"#

private func listed(_ id: String, name: String = "Lint", extra: String = "") -> String {
  #"{"id":"\#(id)","name":"\#(name)","instructions":"Check style","createdAt":"\#(made)","#
    + #""updatedAt":"\#(made)","source":"shared"\#(extra)}"#
}

private func installed(_ id: String = "s1", update: String = "null") -> String {
  listed(id, extra: #","description":"Lints","origin":\#(origin),"update":\#(update)"#)
}

private func record(_ id: String, name: String = "Lint") -> String {
  #"{"id":"\#(id)","name":"\#(name)","instructions":"Check style","createdAt":"\#(made)","updatedAt":"\#(made)"}"#
}

private func package(_ id: String = "s1", name: String = "Lint") -> String {
  #"{"id":"\#(id)","name":"\#(name)","instructions":"Check style","createdAt":"\#(made)","#
    + #""updatedAt":"\#(made)","agentId":null,"description":"Lints","#
    + #""documents":[{"path":"references/a.md","content":"A"}],"createdBy":"owner","#
    + #""sourceExecutionId":null,"useCount":0,"lastUsedAt":null,"state":"active","pinned":false,"#
    + #""origin":\#(origin)}"#
}

private func listing() -> String {
  #"{"repository":"acme/skills","branch":"main","commit":"\#(commit)","path":"","omitted":0,"skills":["#
    + #"{"path":"lint","name":"Lint","description":"","status":"new","problem":null,"skipped":[],"#
    + #""skillId":null},{"path":"old","name":"Old","description":"","status":"installed","problem":null,"#
    + #""skipped":[],"skillId":"s9"},{"path":"bad","name":"Bad","description":"","status":"invalid","#
    + #""problem":"No name","skipped":[],"skillId":null}"#
    + "]}"
}

private func ok(_ body: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(body.utf8), delay: delay)
}

private func refused(_ message: String) -> StubResponse {
  StubResponse(status: 409, body: Data(#"{"error":"\#(message)"}"#.utf8))
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

private func body(_ request: URLRequest) throws -> [String: JSONValue] {
  guard case .object(let object) = try requestJSON(request) else { throw URLError(.cannotDecodeRawData) }
  return object
}

private func path(_ request: URLRequest) -> String {
  String(request.url?.path.dropFirst("/prefix".count) ?? "")
}

@Test func theListCarriesWhereAnInstalledSkillCameFromAndWhatChanged() async throws {
  try await withClient(handler: { _ in
    ok("[\(installed(update: #"{"commit":"\#(commit)","removed":false}"#)),"
      + "\(listed("s2", name: "Own")),\(installed("s3", update: #"{"commit":"\#(commit)","removed":true}"#))]")
  }, test: { client in
    let skills = try await client.sharedSkills()
    #expect(skills.map(\.isInstalled) == [true, false, true])
    #expect(skills[0].summary == "Lints")
    #expect(skills[1].summary == "Check style")
    #expect(skills[0].update?.badge == "Update available")
    #expect(skills[2].update?.badge == "Removed upstream")
    #expect(skills[0].origin?.shortCommit == "aaaaaaa")
    #expect(skills[0].origin?.folderName == "acme/skills/lint")
    #expect(skills[0].origin?.url?.absoluteString == "https://github.com/acme/skills/tree/main/lint")
  })
}

@MainActor @Test func aSharedSkillEditShowsAtOnceAndComesBackOnFailure() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "PATCH" ? refused("Name is taken") : ok("[\(listed("s1"))]")
  }, test: { client in
    let board = SharedSkillBoard()
    board.skills = [SharedSkill(id: "s1", name: "Lint", instructions: "Old", description: "Keep me")]
    let failure = Mutex<String?>(nil)
    board.save(
      skillID: "s1", name: "New", instructions: "Newer", client: client, onSaved: { _ in },
      onFailure: { message in failure.withLock { $0 = message } })
    #expect(board.skill("s1")?.name == "New")
    #expect(board.skill("s1")?.description == "Keep me")
    let second = board.save(
      skillID: "s1", name: "x", instructions: "y", client: client, onSaved: { _ in }, onFailure: { _ in })
    #expect(!second)
    try await wait { board.pending.isEmpty }
    #expect(failure.withLock { $0 }?.contains("Name is taken") == true)
    board.reset()
  })
}

@MainActor @Test func aNewSharedSkillHandsItsRealIDToTheAssignments() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? ok(record("s2"), status: 201, delay: 0.02) : ok("[\(listed("s2"))]")
  }, test: { client in
    let board = SharedSkillBoard()
    let saved = Mutex<String?>(nil)
    board.save(name: "Lint", instructions: "Do", client: client, onSaved: { id in
      saved.withLock { $0 = id }
    }, onFailure: { _ in })
    #expect(board.skills[0].id.hasPrefix("pending-"))
    try await wait { board.pending.isEmpty }
    #expect(saved.withLock { $0 } == "s2")
    #expect(board.skills.map(\.id) == ["s2"])
    board.reset()
  })
}

@MainActor @Test func aCopyKeepsDescriptionAndDocumentsAndIsEditable() async throws {
  let posts = Mutex<[[String: JSONValue]]>([])
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      let sent = try body(request)
      posts.withLock { $0.append(sent) }
      return ok(record("s2", name: "Lint copy"), status: 201)
    }
    return path(request) == "/v1/skills/s1" ? ok(package()) : ok("[\(installed()),\(listed("s2", name: "Lint copy"))]")
  }, test: { client in
    let board = SharedSkillBoard()
    let source = SharedSkill(
      id: "s1", name: "Lint", instructions: "Check style",
      origin: SkillOrigin(repository: "acme/skills", branch: "main", path: "lint", commit: commit))
    board.skills = [source]
    board.copy(source, client: client)
    #expect(board.skills.map(\.name) == ["Lint", "Lint copy"])
    #expect(!board.skills[1].isInstalled)
    try await wait { board.pending.isEmpty }
    #expect(board.skills[1].id == "s2")
    #expect(posts.withLock { $0 } == [[
      "name": .string("Lint copy"), "description": .string("Lints"), "instructions": .string("Check style"),
      "documents": .array([.object(["path": .string("references/a.md"), "content": .string("A")])])
    ]])
    board.reset()
  })
}

@MainActor @Test func aFailedCopyLeavesAndSaysWhy() async throws {
  try await withClient(handler: { request in
    path(request) == "/v1/skills/s1" ? refused("Gone") : ok("[\(listed("s1"))]")
  }, test: { client in
    let board = SharedSkillBoard()
    let source = SharedSkill(id: "s1", name: "Lint", instructions: "x")
    board.skills = [source]
    board.copy(source, client: client)
    #expect(board.skills.count == 2)
    try await wait { board.pending.isEmpty }
    #expect(board.skills.map(\.id) == ["s1"])
    #expect(board.error?.contains("Gone") == true)
    board.reset()
  })
}

@MainActor @Test func aFailedDeleteRestoresTheSkillInPlace() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "DELETE" ? refused("Busy") : ok("[]", delay: 0.2)
  }, test: { client in
    let board = SharedSkillBoard()
    board.skills = ["a", "b", "c"].map { SharedSkill(id: $0, name: $0, instructions: "x") }
    let restored = Mutex(false)
    board.delete("b", client: client) { restored.withLock { $0 = true } }
    #expect(board.skills.map(\.id) == ["a", "c"])
    try await wait { board.pending.isEmpty }
    #expect(board.skills.map(\.id) == ["a", "b", "c"])
    #expect(restored.withLock { $0 })
    #expect(board.error?.contains("Busy") == true)
    board.reset()
  })
}

@MainActor @Test func checkingReportsRepositoriesItCouldNotRead() async throws {
  let check = #"{"failed":[{"repository":"acme/skills","branch":"main","message":"Not found"}]}"#
  try await withClient(handler: { request in
    path(request) == "/v1/skills/updates/check"
      ? ok(check, delay: 0.02) : ok("[\(installed(update: #"{"commit":"\#(commit)","removed":false}"#))]")
  }, test: { client in
    let board = SharedSkillBoard()
    board.checkForUpdates(client: client)
    #expect(board.checking)
    try await wait { !board.checking && !board.skills.isEmpty }
    #expect(board.checkFailures == ["Couldn't check acme/skills (main): Not found"])
    #expect(board.skills[0].update?.removed == false)
    board.reset()
  })
}

@MainActor @Test func installListsPicksNewSkillsAndSendsTheBrowsedCommit() async throws {
  let sent = Mutex<[String: JSONValue]>([:])
  try await withClient(handler: { request in
    if path(request) == "/v1/skills/github/browse" { return ok(listing()) }
    let fields = try body(request)
    sent.withLock { $0 = fields }
    return ok("[\(package())]", status: 201, delay: 0.02)
  }, test: { client in
    let install = SkillInstall()
    #expect(!install.actionReady)
    install.setLocation("acme/skills")
    #expect(install.actionLabel == "Find skills" && install.actionReady)
    install.find(client: client)
    try await wait { install.listing != nil && !install.browsing }
    #expect(install.picked == ["lint"])
    #expect(install.actionLabel == "Install 1 skill")
    #expect(install.listing?.skills[2].note == "No name")
    #expect(install.listing?.skills[1].statusLabel == "Installed")
    install.botIDs = ["a2", "a1"]
    let board = SharedSkillBoard()
    board.sheet = .install(install)
    let done = Mutex(false)
    install.install(board: board, client: client) { done.withLock { $0 = true } }
    #expect(install.installing)
    try await wait { !install.installing }
    #expect(done.withLock { $0 })
    #expect(board.sheet == nil)
    #expect(sent.withLock { $0 } == [
      "repository": .string("acme/skills"), "branch": .string("main"), "commit": .string(commit),
      "paths": .array([.string("lint")]), "botIds": .array([.string("a1"), .string("a2")])
    ])
  })
}

@MainActor @Test func aLateListingForAnEarlierRepositoryIsDropped() async throws {
  try await withClient(handler: { _ in ok(listing(), delay: 0.03) }, test: { client in
    let install = SkillInstall()
    install.setLocation("acme/skills")
    install.find(client: client)
    install.setLocation("acme/other")
    #expect(!install.browsing)
    try await Task.sleep(for: .milliseconds(80))
    #expect(install.listing == nil && install.location == "acme/other")
  })
}

@MainActor @Test func aFailedBrowseKeepsTheLocationAndSaysWhy() async throws {
  try await withClient(handler: { _ in refused("No such repository") }, test: { client in
    let install = SkillInstall()
    install.setLocation("acme/none")
    install.find(client: client)
    try await wait { !install.browsing }
    #expect(install.error?.contains("No such repository") == true)
    #expect(install.location == "acme/none" && install.actionLabel == "Find skills")
  })
}

@MainActor @Test func reviewingAnUpdateDiffsItAndApplyingClearsTheBadge() async throws {
  let upstream = #"{"commit":"\#(commit)","name":"Lint","description":"Lints","instructions":"Check more","#
    + #""documents":[{"path":"references/a.md","content":"A"}],"skipped":["a","b","c","d"]}"#
  try await withClient(handler: { request in
    switch (request.httpMethod, path(request)) {
    case ("GET", "/v1/skills/s1"): ok(package())
    case ("GET", "/v1/skills/s1/update"): ok(upstream)
    case ("POST", "/v1/skills/s1/update"): ok(package(name: "Lint 2"), delay: 0.02)
    default: ok("[\(installed())]", delay: 0.3)
    }
  }, test: { client in
    let board = SharedSkillBoard()
    let skill = SharedSkill(
      id: "s1", name: "Lint", instructions: "Check style", update: SkillUpdate(commit: commit, removed: false))
    board.skills = [skill]
    let review = SkillReview(skill: skill)
    review.load(client: client, includingUpdate: true)
    try await wait { review.diff != nil }
    #expect(review.diff?.filter { $0.kind == .removed }.map(\.text) == ["Check style"])
    #expect(review.diff?.filter { $0.kind == .added }.map(\.text) == ["Check more"])
    #expect(review.skippedNote == "Skips a, b, c and 1 more")
    board.sheet = .update(review)
    review.apply(board: board, client: client)
    #expect(review.applying)
    try await wait { !review.applying }
    #expect(board.sheet == nil)
    #expect(board.skill("s1")?.update == nil)
    #expect(board.skill("s1")?.name == "Lint 2")
    board.reset()
  })
}

@MainActor @Test func aRefusedUpdateKeepsTheBadgeAndTheSheet() async throws {
  try await withClient(handler: { request in
    switch (request.httpMethod, path(request)) {
    case ("GET", "/v1/skills/s1"): ok(package())
    case ("GET", "/v1/skills/s1/update"):
      ok(#"{"commit":"\#(commit)","name":"Lint","description":"","instructions":"","documents":[],"skipped":[]}"#)
    case ("POST", _): refused("Upstream moved")
    default: ok("[\(installed(update: #"{"commit":"\#(commit)","removed":false}"#))]")
    }
  }, test: { client in
    let board = SharedSkillBoard()
    let skill = SharedSkill(
      id: "s1", name: "Lint", instructions: "x", update: SkillUpdate(commit: commit, removed: false))
    board.skills = [skill]
    let review = SkillReview(skill: skill)
    review.load(client: client, includingUpdate: true)
    try await wait { review.pendingUpdate != nil }
    board.sheet = .update(review)
    review.apply(board: board, client: client)
    try await wait { !review.applying }
    #expect(review.error?.contains("Upstream moved") == true)
    #expect(board.skill("s1")?.update != nil)
    #expect(board.sheet?.id == review.id)
    #expect(board.error == nil)
    board.reset()
  })
}

@MainActor private func updating(_ client: APIClient, board: SharedSkillBoard) async throws -> SkillReview {
  let skill = SharedSkill(
    id: "s1", name: "Lint", instructions: "x", update: SkillUpdate(commit: commit, removed: false))
  board.skills = [skill]
  let review = SkillReview(skill: skill)
  review.load(client: client, includingUpdate: true)
  try await wait { review.pendingUpdate != nil }
  board.sheet = .update(review)
  return review
}

private func updateServer(_ request: URLRequest, apply: StubResponse) -> StubResponse {
  switch (request.httpMethod, path(request)) {
  case ("GET", "/v1/skills/s1"): ok(package())
  case ("GET", "/v1/skills/s1/update"):
    ok(#"{"commit":"\#(commit)","name":"Lint","description":"","instructions":"","documents":[],"skipped":[]}"#)
  case ("POST", _): apply
  default: ok("[\(installed())]", delay: 0.2)
  }
}

@MainActor @Test func aRefusedUpdateTheOwnerLeftShowsOnThePage() async throws {
  try await withClient(handler: { updateServer($0, apply: refused("Upstream moved")) }, test: { client in
    let board = SharedSkillBoard()
    let review = try await updating(client, board: board)
    review.apply(board: board, client: client)
    board.sheet = nil
    try await wait { !review.applying }
    #expect(board.error?.contains("Upstream moved") == true)
    board.reset()
  })
}

@MainActor @Test func aFinishedUpdateLeavesANewerSheetOpen() async throws {
  try await withClient(handler: { updateServer($0, apply: ok(package(), delay: 0.02)) }, test: { client in
    let board = SharedSkillBoard()
    let review = try await updating(client, board: board)
    review.apply(board: board, client: client)
    let newer = SkillInstall()
    board.sheet = .install(newer)
    try await wait { !review.applying }
    #expect(board.sheet?.id == newer.id)
    board.reset()
  })
}

@MainActor @Test func anUpdateWaitsForAWriteAlreadyRunningOnTheSkill() async throws {
  try await withClient(handler: { request in
    if request.httpMethod == "DELETE" { return ok("", status: 204, delay: 0.05) }
    return updateServer(request, apply: ok(package()))
  }, test: { client in
    let board = SharedSkillBoard()
    let review = try await updating(client, board: board)
    board.delete("s1", client: client) {}
    review.apply(board: board, client: client)
    #expect(!review.applying)
    board.reset()
  })
}

@MainActor private func listed(_ install: SkillInstall, client: APIClient) async throws {
  install.setLocation("acme/skills")
  install.find(client: client)
  try await wait { install.listing != nil && !install.browsing }
}

private func installServer(_ request: URLRequest, answer: StubResponse) -> StubResponse {
  path(request) == "/v1/skills/github/browse" ? ok(listing()) : answer
}

@MainActor @Test func aFailedInstallKeepsTheSheetOrShowsOnThePageOnceLeft() async throws {
  let refusal = StubResponse(status: 409, body: Data(#"{"error":"GitHub is unavailable"}"#.utf8), delay: 0.02)
  try await withClient(handler: { installServer($0, answer: refusal) }, test: { client in
    let board = SharedSkillBoard()
    let install = SkillInstall()
    try await listed(install, client: client)
    board.sheet = .install(install)
    install.install(board: board, client: client) { Issue.record("Must not finish") }
    try await wait { !install.installing }
    #expect(install.error?.contains("GitHub is unavailable") == true)
    #expect(board.sheet?.id == install.id)
    #expect(board.error == nil)

    install.install(board: board, client: client) { Issue.record("Must not finish") }
    board.sheet = nil
    try await wait { !install.installing }
    #expect(board.error?.contains("GitHub is unavailable") == true)
  })
}

@MainActor @Test func aFinishedInstallLeavesANewerSheetOpen() async throws {
  let installed = ok("[\(package())]", status: 201, delay: 0.02)
  try await withClient(handler: { installServer($0, answer: installed) }, test: { client in
    let board = SharedSkillBoard()
    let install = SkillInstall()
    try await listed(install, client: client)
    board.sheet = .install(install)
    let done = Mutex(false)
    install.install(board: board, client: client) { done.withLock { $0 = true } }
    let newer = SkillInstall()
    board.sheet = .install(newer)
    try await wait { !install.installing }
    #expect(done.withLock { $0 })
    #expect(board.sheet?.id == newer.id)
  })
}

@MainActor @Test func anInstallAnswerFromTheOldConnectionIsDropped() async throws {
  let refusal = StubResponse(status: 409, body: Data(#"{"error":"GitHub is unavailable"}"#.utf8), delay: 0.02)
  try await withClient(handler: { installServer($0, answer: refusal) }, test: { client in
    let board = SharedSkillBoard()
    let install = SkillInstall()
    try await listed(install, client: client)
    board.sheet = .install(install)
    install.install(board: board, client: client) { Issue.record("Must not finish") }
    board.reset()
    try await wait { !install.installing }
    #expect(board.error == nil)
  })
}

@Test func bulkDeleteReportsEachFailureAndKeepsItSelected() async throws {
  try await withClient(handler: { request in
    path(request) == "/v1/agents/a1/skills/s2"
      ? StubResponse(status: 204, body: Data()) : refused("Busy")
  }, test: { client in
    let result = await runBulkSkillAction(
      .delete,
      picked: [
        SelectableSkill(id: "s1", name: "One"),
        SelectableSkill(id: "s2", name: "Two", agentID: "a1", ownerName: "Atlas")
      ],
      bots: [], client: client)
    #expect(result.failed == ["s1"])
    #expect(result.messages.map(\.text) == [
      "1 of 2 skills processed; 1 failed and remain selected.", "Failed One (Shared): Busy"
    ])
  })
}

@Test func bulkUpdateSkipsWhatItCannotUpdateAndFailsOnACheckFailure() async throws {
  let applied = Mutex<[String]>([])
  let catalog = "[\(installed("s1", update: #"{"commit":"\#(commit)","removed":false}"#)),\(installed("s2"))]"
  try await withClient(handler: { request in
    switch (request.httpMethod, path(request)) {
    case ("POST", "/v1/skills/updates/check"): return ok(#"{"failed":[]}"#)
    case ("GET", "/v1/skills"): return ok(catalog)
    default:
      applied.withLock { $0.append(path(request)) }
      return ok(package())
    }
  }, test: { client in
    let result = await runBulkSkillAction(
      .update,
      picked: [
        SelectableSkill(id: "s1", name: "One", isInstalled: true),
        SelectableSkill(id: "s2", name: "Two", isInstalled: true),
        SelectableSkill(id: "s3", name: "Mine")
      ],
      bots: [], client: client)
    #expect(applied.withLock { $0 } == ["/v1/skills/s1/update"])
    #expect(result.failed.isEmpty)
    #expect(result.messages.map(\.text) == [
      "3 of 3 skills processed.", "Skipped Two (Shared): already up to date.",
      "Skipped Mine (Shared): not installed from GitHub."
    ])
  })
  try await withClient(handler: { request in
    path(request) == "/v1/skills/updates/check"
      ? ok(#"{"failed":[{"repository":"acme/skills","branch":"main","message":"Not found"}]}"#) : ok(catalog)
  }, test: { client in
    let result = await runBulkSkillAction(
      .update, picked: [SelectableSkill(id: "s1", name: "One", isInstalled: true)], bots: [], client: client)
    #expect(result.failed == ["s1"])
    #expect(result.messages.last?.text == "Failed One (Shared): Not found")
  })
}

@Test func bulkAssignKeepsBotOrderCapsRequestsAndReportsPartialFailure() async throws {
  let running = Mutex((now: 0, most: 0))
  let bots = (1...6).map { BulkSkillBot(id: "a\($0)", name: "Bot\($0)") }
  try await withClient(handler: { request in
    running.withLock { state in
      state.now += 1
      state.most = max(state.most, state.now)
    }
    Thread.sleep(forTimeInterval: 0.01)
    running.withLock { $0.now -= 1 }
    guard case .string(let bot)? = try body(request)["botId"] else { throw URLError(.badURL) }
    if bot == "a1" { return ok(#"{"skipped":true}"#) }
    return bot == "a2" ? refused("Nope") : ok(#"{"skipped":false}"#)
  }, test: { client in
    let result = await runBulkSkillAction(
      .assign, picked: [SelectableSkill(id: "s1", name: "One")], bots: bots, client: client)
    #expect(running.withLock { $0.most } <= 4)
    #expect(result.failed == ["s1"])
    #expect(result.messages.map(\.text) == [
      "0 of 1 skills processed; 1 failed and remain selected.",
      "Skipped One (Shared) → Bot1: already in the requested state.",
      "Failed One (Shared) → Bot2: Nope"
    ])
  })
}

@MainActor @Test func aBulkDeleteHidesSkillsAndBringsFailuresBackSelected() async throws {
  try await withClient(handler: { request in
    path(request) == "/v1/skills/s1" ? StubResponse(status: 204, body: Data(), delay: 0.02) : refused("Busy")
  }, test: { client in
    let board = SkillBulkBoard()
    let picked = [SelectableSkill(id: "s1", name: "One"), SelectableSkill(id: "s2", name: "Two")]
    board.change(["s1", "s2"], isOn: true)
    let deleted = Mutex<Set<String>>([])
    let finished = Mutex(false)
    board.run(.delete, picked: picked, bots: [], client: client, deleted: { ids in
      deleted.withLock { $0 = ids }
    }, finished: { finished.withLock { $0 = true } })
    #expect(board.hidden == ["s1", "s2"] && board.isRunning && board.runningCount == 2)
    try await wait { !board.isRunning }
    #expect(deleted.withLock { $0 } == ["s1"])
    #expect(board.hidden.isEmpty && board.selected == ["s2"])
    #expect(finished.withLock { $0 })
    #expect(board.report[0].text == "1 of 2 skills processed; 1 failed and remain selected.")
  })
}

@MainActor @Test func aSelectionKnowsWhenAGroupIsPartlyPicked() {
  let board = SkillBulkBoard()
  board.change(["a"], isOn: true)
  #expect(board.state(of: ["a", "b"]) == .some)
  board.change(["a", "b"], isOn: true)
  #expect(board.state(of: ["a", "b"]) == .all)
  board.change(["a", "b"], isOn: false)
  #expect(board.state(of: ["a", "b"]) == .none)
}

@MainActor @Test func theCatalogFiltersBySearchAndOwner() async throws {
  try await withClient(handler: { _ in
    let bot = #"{"id":"b1","name":"Triage","instructions":"Sort","createdAt":"\#(made)","updatedAt":"\#(made)","#
      + #""agentId":"a1","description":"","documents":[],"createdBy":"owner","sourceExecutionId":null,"#
      + #""useCount":0,"lastUsedAt":null,"state":"active","pinned":false}"#
    return ok("[\(bot)]")
  }, test: { client in
    let botSkills = BotSkillBoard()
    botSkills.refresh(agentID: "a1", client: client)
    try await wait { botSkills.isLoaded(agentID: "a1") }
    let agents = [Agent(id: "a1", name: "Atlas"), Agent(id: "a2", name: "Juniper")]
    let skills = [
      SharedSkill(id: "s1", name: "Lint", instructions: "Check", source: "shared"),
      SharedSkill(id: "d1", name: "Tasks", instructions: "Do", source: "bundled"),
      SharedSkill(id: "pending-skill-1", name: "New", instructions: "x", source: "shared")
    ]
    @MainActor func catalog(_ scope: SkillScope, _ search: String = "", hidden: Set<String> = []) -> SkillCatalog {
      SkillCatalog(skills: skills, agents: agents, botSkills: botSkills, hidden: hidden, scope: scope, search: search)
    }
    #expect(catalog(.all).visibleIDs == ["s1", "b1"])
    #expect(catalog(.all, " SORT ").visibleIDs == ["b1"])
    #expect(catalog(.shared).visibleIDs == ["s1"])
    #expect(catalog(.bot("a1")).visibleIDs == ["b1"])
    #expect(catalog(.defaults).visibleIDs.isEmpty)
    #expect(catalog(.all, hidden: ["s1"]).visibleIDs == ["b1"])
    #expect(catalog(.bot("a2")).visibleOwners.map(\.id) == ["a2"])
    #expect(catalog(.shared).visibleOwners.isEmpty)
    #expect(catalog(.shared, "check").visibleDefaults.isEmpty)
    #expect(catalog(.all).options.map(\.title) == [
      "All", "Shared (2)", "Atlas (1)", "Juniper", "Default (1)"
    ])
    #expect(catalog(.all).picked(["s1"]).map(\.label) == ["Lint (Shared)"])
  })
}

@Test func theAssignmentChangesTakeBotsToTheSelection() {
  let agents = [Agent(id: "a1", name: "A", sharedSkills: ["s"]), Agent(id: "a2", name: "B"),
                Agent(id: "a3", name: "C", sharedSkills: ["s"])]
  #expect(agents.using(skill: "s") == ["a1", "a3"])
  let changes = agents.assignmentChanges(skill: "s", selected: ["a2", "a3"])
  #expect(changes.map(\.agentID) == ["a1", "a2"])
  #expect(changes.map(\.enabled) == [false, true])
}

@Test func limitsCountAsTheServerCountsAndNeverSplitACharacter() {
  #expect(SkillLimits.name(String(repeating: "a", count: 101)).count == 100)
  #expect(SkillLimits.name(String(repeating: "a", count: 99) + "😀").utf16.count == 99)
  #expect(SkillLimits.instructions("short") == "short")
  #expect(SkillLimits.copyName(String(repeating: "a", count: 100)).count == 100)
}

@Test func aDiffKeepsItsLinesInOrder() {
  let lines = skillDiff(before: ["a", "b", "c", "d"], after: ["a", "x", "c", "y", "d"])
  #expect(lines.map { $0.kind.rawValue + $0.text } == [" a", "-b", "+x", " c", "+y", " d"])
  #expect(skillDiff(before: [], after: ["a"]).map(\.kind) == [.added])
  #expect(skippedSkillFilesNote([]) == nil)
  #expect(skippedSkillFilesNote(["a"]) == "Skips a")
}
