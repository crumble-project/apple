import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let made = "2026-11-05T10:00:00Z"

private func package(_ id: String = "s1", name: String = "Triage", pinned: Bool = false) -> String {
  #"{"id":"\#(id)","name":"\#(name)","instructions":"Sort the queue","createdAt":"\#(made)","#
    + #""updatedAt":"\#(made)","agentId":"a1","description":"","documents":[],"createdBy":"owner","#
    + #""sourceExecutionId":null,"useCount":0,"lastUsedAt":null,"state":"active","pinned":\#(pinned)}"#
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

@MainActor
private func loaded(_ client: APIClient) async throws -> BotSkillBoard {
  let board = BotSkillBoard()
  board.refresh(agentID: "a1", client: client)
  try await wait { board.isLoaded(agentID: "a1") }
  return board
}

private func body(_ request: URLRequest) throws -> [String: JSONValue] {
  guard case .object(let object) = try requestJSON(request) else { throw URLError(.cannotDecodeRawData) }
  return object
}

@Test func aGlimpseIsTheFirstLineWithoutHeadingMarks() {
  let skill = BotSkill(id: "s1", agentID: "a1", name: "Triage", instructions: "\n## Sort the queue\nThen reply")
  #expect(skill.glimpse == "Sort the queue")
  #expect(BotSkill(id: "s2", agentID: "a1", name: "Empty", instructions: "").glimpse == "No instructions.")
}

@MainActor @Test func aNewSkillShowsAtOnceAndBecomesTheServersRecord() async throws {
  let posts = Mutex<[[String: JSONValue]]>([])
  try await withClient(handler: { request in
    guard request.httpMethod == "POST" else { return ok("[\(package("s2", name: "Added"))]") }
    #expect(request.url?.path == "/prefix/v1/agents/a1/skills")
    let sent = try body(request)
    posts.withLock { $0.append(sent) }
    return ok(package("s2", name: "Added"), status: 201, delay: 0.05)
  }, test: { client in
    let board = BotSkillBoard()
    board.save(agentID: "a1", name: "Added", instructions: "Do it", client: client) { _ in }
    #expect(board.skills(agentID: "a1").map(\.name) == ["Added"])
    #expect(board.skills(agentID: "a1")[0].id.hasPrefix("pending-"))
    #expect(board.pending.count == 1)
    try await wait { board.pending.isEmpty }
    #expect(board.skills(agentID: "a1").map(\.id) == ["s2"])
    #expect(posts.withLock { $0 } == [["name": .string("Added"), "instructions": .string("Do it")]])
    board.reset()
  })
}

@MainActor @Test func aRefusedSkillLeavesAndHandsBackTheDraft() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? refused("Name is taken") : ok("[]")
  }, test: { client in
    let board = try await loaded(client)
    let failure = Mutex<String?>(nil)
    board.save(agentID: "a1", name: "Taken", instructions: "Do it", client: client) { message in
      failure.withLock { $0 = message }
    }
    try await wait { board.pending.isEmpty }
    #expect(failure.withLock { $0 }?.contains("Name is taken") == true)
    #expect(board.skills(agentID: "a1").isEmpty)
    #expect(board.errors["a1"] == nil)
    board.reset()
  })
}

@MainActor @Test func anEditSendsNameAndInstructionsAndRollsBack() async throws {
  let patches = Mutex<[[String: JSONValue]]>([])
  try await withClient(handler: { request in
    guard request.httpMethod == "PATCH" else { return ok("[\(package())]") }
    #expect(request.url?.path == "/prefix/v1/agents/a1/skills/s1")
    let sent = try body(request)
    patches.withLock { $0.append(sent) }
    return refused("Busy")
  }, test: { client in
    let board = try await loaded(client)
    #expect(board.save(
      agentID: "a1", skillID: "s1", name: "Renamed", instructions: "New", client: client) { _ in })
    #expect(board.skills(agentID: "a1")[0].name == "Renamed")
    #expect(!board.save(
      agentID: "a1", skillID: "s1", name: "Again", instructions: "New", client: client) { _ in })
    try await wait { board.pending.isEmpty }
    #expect(board.skills(agentID: "a1")[0].name == "Triage")
    #expect(patches.withLock { $0 } == [["name": .string("Renamed"), "instructions": .string("New")]])
    board.reset()
  })
}

@MainActor @Test func aDeletedSkillStaysGoneWhileAnOlderReadLands() async throws {
  let reads = Mutex(0)
  let deleted = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "DELETE" {
      deleted.withLock { $0 = true }
      return StubResponse(status: 204, body: Data(), delay: 0.05)
    }
    let count = reads.withLock { $0 += 1; return $0 }
    if deleted.withLock({ $0 }) { return ok("[]") }
    return ok("[\(package())]", delay: count == 2 ? 0.02 : 0)
  }, test: { client in
    let board = try await loaded(client)
    let skill = try #require(board.skills(agentID: "a1").first)
    board.refresh(agentID: "a1", client: client)
    board.delete(skill, client: client)
    #expect(board.skills(agentID: "a1").isEmpty)
    board.refresh(agentID: "a1", client: client)
    try await wait { board.pending.isEmpty }
    #expect(board.skills(agentID: "a1").isEmpty)
    try await wait { reads.withLock { $0 } >= 2 }
    #expect(board.skills(agentID: "a1").isEmpty)
    board.reset()
  })
}

@MainActor @Test func aFailedDeleteComesBackWithItsError() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "DELETE" ? refused("Busy") : ok("[\(package("s1")),\(package("s2", name: "Second"))]")
  }, test: { client in
    let board = try await loaded(client)
    let skill = try #require(board.skill("s1", agentID: "a1"))
    board.delete(skill, client: client)
    #expect(board.skills(agentID: "a1").map(\.id) == ["s2"])
    try await wait { board.pending.isEmpty }
    #expect(board.skills(agentID: "a1").map(\.id) == ["s1", "s2"])
    #expect(board.errors["a1"]?.contains("Busy") == true)
    board.reset()
  })
}

@MainActor @Test func pinningSendsOnlyThePin() async throws {
  let patches = Mutex<[[String: JSONValue]]>([])
  try await withClient(handler: { request in
    guard request.httpMethod == "PATCH" else { return ok("[\(package(pinned: !patches.withLock { $0 }.isEmpty))]") }
    let sent = try body(request)
    patches.withLock { $0.append(sent) }
    return ok(package(pinned: true))
  }, test: { client in
    let board = try await loaded(client)
    let skill = try #require(board.skills(agentID: "a1").first)
    board.setPinned(skill, pinned: true, client: client)
    #expect(board.skills(agentID: "a1")[0].pinned)
    try await wait { board.pending.isEmpty }
    #expect(board.skills(agentID: "a1")[0].pinned)
    #expect(patches.withLock { $0 } == [["pinned": .bool(true)]])
    board.reset()
  })
}

@MainActor @Test func resetDropsALateAnswer() async throws {
  try await withClient(handler: { _ in ok("[\(package())]", delay: 0.05) }, test: { client in
    let board = BotSkillBoard()
    board.refresh(agentID: "a1", client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(120))
    #expect(!board.isLoaded(agentID: "a1"))
  })
}

@Test func assigningASharedSkillNamesTheBot() async throws {
  let sent = Mutex<(String?, [String: JSONValue])>((nil, [:]))
  try await withClient(handler: { request in
    let values = try body(request)
    sent.withLock { $0 = (request.url?.path, values) }
    return ok(#"{"skipped":false}"#)
  }, test: { client in
    try await client.assignSharedSkill("s1", agentID: "a1", assigned: true)
    let (path, values) = sent.withLock { $0 }
    #expect(path == "/prefix/v1/skills/s1/assignment")
    #expect(values == ["botId": .string("a1"), "assigned": .bool(true)])
  })
}
