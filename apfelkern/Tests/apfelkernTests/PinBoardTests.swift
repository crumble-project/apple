import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private func session(_ keys: [String]) -> String {
  let list = keys.map { "\"\($0)\"" }.joined(separator: ",")
  return #"{"user":{"pinnedConversations":[\#(list)]}}"#
}

private func isRead(_ request: URLRequest) -> Bool { request.httpMethod == "GET" }

private func wrote(_ request: URLRequest) -> JSONValue? { try? requestJSON(request) }

private func written(_ keys: [String]) -> JSONValue {
  .object(["pinnedConversations": .array(keys.map(JSONValue.string))])
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

@MainActor
private func loaded(_ keys: [String], client: APIClient) async throws -> PinBoard {
  let board = PinBoard()
  board.refresh(client: client)
  try await wait { board.isLoaded }
  #expect(board.pins.keys == keys)
  return board
}

@MainActor @Test func refreshLoadsAccountPins() async throws {
  try await withClient(handler: { _ in json(session(["agent:1"])) }, test: { client in
    _ = try await loaded(["agent:1"], client: client)
  })
}

@MainActor @Test func aServerWithoutPinsLeavesThemUnavailable() async throws {
  try await withClient(handler: { _ in json(#"{"user":{"theme":"dark"}}"#) }, test: { client in
    let board = PinBoard()
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(50))
    #expect(!board.isLoaded)
  })
}

@MainActor @Test func changeShowsAtOnceAndRollsBackOnFailure() async throws {
  try await withClient(handler: { request in
    isRead(request) ? json(session(["agent:1"])) : json(#"{"error":"nope"}"#, status: 500)
  }, test: { client in
    let board = try await loaded(["agent:1"], client: client)
    var failures = 0
    board.change(
      PinnedConversations(keys: ["agent:1", "agent:2"]), client: client, session: client.session,
      onFailure: { _ in failures += 1 })
    #expect(board.pins.keys == ["agent:1", "agent:2"])
    try await wait { failures == 1 }
    #expect(board.pins.keys == ["agent:1"])
  })
}

@MainActor @Test func writesRunOneAtATimeAndEndOnTheNewest() async throws {
  let writes = Mutex<[JSONValue?]>([])
  try await withClient(handler: { request in
    if isRead(request) { return json(session([])) }
    writes.withLock { $0.append(wrote(request)) }
    return json(#"{"status":true}"#, delay: 0.03)
  }, test: { client in
    let board = try await loaded([], client: client)
    for keys in [["agent:1"], ["agent:1", "agent:2"], ["agent:2"]] {
      board.change(PinnedConversations(keys: keys), client: client, session: client.session, onFailure: { _ in })
    }
    try await wait { writes.withLock { $0.last } == written(["agent:2"]) }
    try await wait { !board.isWriting }
    #expect(writes.withLock { $0 } == [written(["agent:1"]), written(["agent:2"])])
    #expect(board.pins.keys == ["agent:2"])
  })
}

@MainActor @Test func receiveIgnoredWhileAWriteIsPending() async throws {
  try await withClient(handler: { request in
    isRead(request) ? json(session(["agent:1"])) : json(#"{"status":true}"#, delay: 0.05)
  }, test: { client in
    let board = try await loaded(["agent:1"], client: client)
    board.change(
      PinnedConversations(keys: ["agent:2"]), client: client, session: client.session, onFailure: { _ in })
    board.receive(["group:old"])
    #expect(board.pins.keys == ["agent:2"])
    try await wait { !board.isWriting }
    #expect(board.pins.keys == ["agent:2"])
    board.receive(["group:new"])
    #expect(board.pins.keys == ["group:new"])
  })
}

@MainActor @Test func changeBeforeLoadIsRefused() async throws {
  let requests = Mutex(0)
  try await withClient(handler: { _ in
    requests.withLock { $0 += 1 }
    return json(session(["agent:1"]), delay: 0.1)
  }, test: { client in
    let board = PinBoard()
    board.change(
      PinnedConversations(keys: ["agent:2"]), client: client, session: client.session,
      onFailure: { _ in Issue.record("nothing to write") })
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.pins.keys.isEmpty)
    #expect(requests.withLock { $0 } == 0)
  })
}

@MainActor @Test func aNewConnectionForgetsThePins() async throws {
  try await withClient(handler: { _ in json(session(["agent:1"])) }, test: { client in
    let board = try await loaded(["agent:1"], client: client)
    board.reset()
    #expect(board.pins.keys.isEmpty)
    #expect(!board.isLoaded)
  })
}
