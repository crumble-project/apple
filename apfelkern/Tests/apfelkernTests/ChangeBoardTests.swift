import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private let stamps = #""createdAt":"2026-11-05T10:00:00.000Z","updatedAt":"2026-11-05T10:00:00.000Z""#

private func memory(_ content: String) -> String {
  #"{"id":"m1","agentId":null,"content":"\#(content)","source":null,\#(stamps)}"#
}

private func skill(_ name: String) -> String {
  #"{"id":"s1","name":"\#(name)","description":"","instructions":"Do it","documents":[],\#(stamps),"#
    + #""agentId":null,"createdBy":"owner","sourceExecutionId":null,"useCount":0,"lastUsedAt":null,"#
    + #""state":"active","pinned":false}"#
}

private func change(
  _ id: String, agent: String = "null", actor: String = "review", target: String = "memory",
  action: String = "update", before: String = "null", after: String = "null"
) -> String {
  #"{"id":"\#(id)","agentId":\#(agent),"actor":"\#(actor)","target":"\#(target)","targetId":"m1","#
    + #""action":"\#(action)","before":\#(before),"after":\#(after),"source":null,"revertsId":null,"#
    + #""createdAt":"2026-11-05T10:00:00.000Z"}"#
}

private func page(_ ids: [String]) -> StubResponse {
  json("[" + ids.map { change($0) }.joined(separator: ",") + "]")
}

private func isRevert(_ request: URLRequest) -> Bool { request.url?.path.hasSuffix("/revert") == true }

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

private func learned(_ text: String) throws -> LearnedChange {
  try LearnedChange(wire: JSONDecoder().decode(Components.Schemas.LearnedChange.self, from: Data(text.utf8)))
}

@Test func changesDescribeThemselvesAsTheWebDoes() throws {
  let review = try learned(change(
    "1", agent: #""a1""#, actor: "review", target: "skill", before: skill("Old"), after: skill("New")))
  #expect(review.summary(botName: "Atlas") == "Atlas's review changed a skill")
  #expect(review.summary(botName: nil) == "A review changed a skill")
  #expect(review.title == "New")
  #expect(review.revertNote.hasPrefix("The skill goes back to how it was"))

  let shared = try learned(change("2", actor: "owner", action: "create", after: memory(#"First\nSecond"#)))
  #expect(shared.summary(botName: nil) == "You added a shared memory")
  #expect(shared.title == "First")
  #expect(shared.revertNote.hasPrefix("The memory is deleted again."))
  #expect(shared.diff.map(\.kind) == [.added, .added])

  let curator = try learned(change(
    "3", agent: #""a1""#, actor: "curator", action: "delete", before: memory("Gone")))
  #expect(curator.summary(botName: "Atlas") == "The curator deleted a memory")
  #expect(curator.title == "Gone")
  #expect(curator.diff == [SkillDiffLine(kind: .removed, text: "Gone")])
}

@Test func activityDaysGroupByCalendarDayInListOrder() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
  calendar.locale = Locale(identifier: "en_US")
  let now = try #require(automationRunDate("2026-11-05T12:00:00Z"))
  let dated = ["2026-11-05T01:00:00Z", "2026-11-04T23:00:00Z", "2026-11-05T02:00:00Z", "2026-11-01T02:00:00Z",
               "2025-03-01T02:00:00Z"]
  let days = activityDays(dated + ["never"], date: automationRunDate, now: now, calendar: calendar)
  #expect(days.count == 5)
  #expect(days[0].label == "Today")
  #expect(days[0].items.count == 2)
  #expect(days[1].label == "Yesterday")
  #expect(days[2].label.contains("Sunday"))
  #expect(!days[2].label.contains("2026"))
  #expect(days[3].label.contains("2025"))
  #expect(days[4].label == "Earlier")
}

@MainActor
@Test func activityFeedKeepsChangesBesideOperationalEntries() async throws {
  let feed = #"{"activities":[{"id":"c1","agentId":null,"agentName":null,"timestamp":1700000000000,"#
    + #""kind":"change","change":\#(change("1", actor: "owner"))},{"id":"t1","agentId":"a1","agentName":"Atlas","#
    + #""entryId":"e1","timestamp":1700000000001,"kind":"tool-call","details":{"toolName":"read"}}],"#
    + #""hasMore":false,"nextCursor":null}"#
  try await withClient(handler: { _ in json(feed) }, test: { client in
    let activities = try await client.activityFeed().activities
    #expect(activities.map(\.kind) == ["change", "tool-call"])
    #expect(activities[0].change?.summary(botName: nil) == "You changed a shared memory")
    #expect(activities[0].agentId == nil)
    #expect(activities[1].change == nil)
  })
}

@MainActor
@Test func changesPageByTheLastChangeAndRefreshGoesBackToTheNewest() async throws {
  let queries = Mutex<[String]>([])
  try await withClient(handler: { request in
    queries.withLock { $0.append(request.url?.query ?? "") }
    return page(request.url?.query?.contains("before=b") == true ? ["c"] : ["a", "b"])
  }, test: { client in
    let board = ChangeBoard(pageSize: 2)
    board.refresh(client: client)
    try await wait { board.isLoaded }
    #expect(board.hasMore)
    board.loadMore(client: client)
    try await wait { board.changes.count == 3 }
    #expect(!board.hasMore)
    #expect(!board.isLoadingMore)
    board.refresh(client: client)
    try await wait { board.changes.count == 2 }
    #expect(queries.withLock { $0 }.contains { $0.contains("before=b") && $0.contains("limit=2") })
  })
}

@MainActor
@Test func aBotFilterDropsTheAnswerToTheOldList() async throws {
  try await withClient(handler: { request in
    request.url?.query?.contains("agentId=a1") == true ? page(["mine"]) : json("[\(change("slow"))]", delay: 0.1)
  }, test: { client in
    let board = ChangeBoard()
    board.refresh(client: client)
    board.show(botID: "a1", client: client)
    try await wait { board.isLoaded }
    try await Task.sleep(for: .milliseconds(150))
    #expect(board.changes.map(\.id) == ["mine"])
  })
}

@MainActor
@Test func aRevertShowsPendingThenItsRecordedChange() async throws {
  try await withClient(handler: { request in
    isRevert(request) ? json(change("r", action: "revert"), status: 201, delay: 0.05) : page(["a"])
  }, test: { client in
    let board = ChangeBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let target = try #require(board.changes.first)
    var settled = 0
    board.revert(target, client: client) { settled += 1 }
    #expect(board.isReverting(target))
    #expect(board.changes.map(\.id) == ["a"])
    board.revert(target, client: client) { settled += 1 }
    try await wait { settled > 0 }
    #expect(settled == 1)
    #expect(!board.isReverting(target))
    #expect(board.changes.map(\.id) == ["r", "a"])
  })
}

@MainActor
@Test func aFailedRevertKeepsTheRowWithItsErrorAndRereadsTheList() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { request in
    if isRevert(request) { return json(#"{"error":"Change not found"}"#, status: 404) }
    return reads.withLock { value in
      value += 1
      return value == 1 ? page(["a"]) : page(["r", "a"])
    }
  }, test: { client in
    let board = ChangeBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let target = try #require(board.changes.first)
    var settled = false
    board.revert(target, client: client) { settled = true }
    try await wait { settled && board.changes.count == 2 }
    #expect(board.errors["a"] == "Change not found")
    #expect(board.changes.map(\.id) == ["r", "a"])
    #expect(!board.isReverting(target))
  })
}

@MainActor
@Test func aFailedRevertKeepsTheOlderPagesOnScreen() async throws {
  let queries = Mutex<[String]>([])
  try await withClient(handler: { request in
    if isRevert(request) { return json(#"{"error":"Timed out"}"#, status: 504) }
    let query = request.url?.query ?? ""
    queries.withLock { $0.append(query) }
    if query.contains("before=b") { return page(["c"]) }
    return query.contains("limit=3") ? page(["a", "b", "c"]) : page(["a", "b"])
  }, test: { client in
    let board = ChangeBoard(pageSize: 2)
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.loadMore(client: client)
    try await wait { board.changes.count == 3 }
    let target = try #require(board.changes.last)
    var settled = false
    board.revert(target, client: client) { settled = true }
    try await wait { settled && queries.withLock { $0.count } == 3 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(queries.withLock { $0.last }?.contains("limit=3") == true)
    #expect(board.changes.map(\.id) == ["a", "b", "c"])
    #expect(board.errors["c"] == "Timed out")
  })
}

@MainActor
@Test func aDeletedBotsFilterGoesBackToEveryBot() async throws {
  try await withClient(handler: { request in
    request.url?.query?.contains("agentId=gone") == true
      ? json(#"{"error":"Agent not found"}"#, status: 404) : page(["all"])
  }, test: { client in
    let board = ChangeBoard()
    board.show(botID: "gone", client: client)
    try await wait { board.isLoaded }
    #expect(board.botID == nil)
    #expect(board.readError == nil)
    #expect(board.changes.map(\.id) == ["all"])
  })
}

@MainActor
@Test func aFailedReadOfEveryBotKeepsItsError() async throws {
  try await withClient(handler: { _ in json(#"{"error":"Not here"}"#, status: 404) }, test: { client in
    let board = ChangeBoard()
    board.refresh(client: client)
    try await wait { board.readError != nil }
    #expect(board.readError == "Not here")
  })
}

@MainActor
@Test func aReadThatLeftBeforeARevertCantDropIt() async throws {
  let reads = Mutex(0)
  try await withClient(handler: { request in
    if isRevert(request) { return json(change("r", action: "revert"), status: 201) }
    let read = reads.withLock { value in
      value += 1
      return value
    }
    return read == 1 ? page(["a"]) : json("[\(change("a"))]", delay: 0.1)
  }, test: { client in
    let board = ChangeBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.refresh(client: client)
    try await wait { reads.withLock { $0 } == 2 }
    var settled = false
    board.revert(try #require(board.changes.first), client: client) { settled = true }
    try await wait { settled }
    try await Task.sleep(for: .milliseconds(150))
    #expect(board.changes.map(\.id) == ["r", "a"])
  })
}

@MainActor
@Test func aLateRevertNeverReachesANewConnection() async throws {
  try await withClient(handler: { request in
    isRevert(request) ? json(change("r", action: "revert"), status: 201, delay: 0.05) : page(["a"])
  }, test: { client in
    let board = ChangeBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    var settled = false
    board.revert(try #require(board.changes.first), client: client) { settled = true }
    board.reset()
    try await Task.sleep(for: .milliseconds(100))
    #expect(board.changes.isEmpty)
    #expect(!settled)
  })
}
