import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let address = "https://relay.example.com/hook/made-up-secret"

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private func source(_ id: String, usedBy: Int = 0) -> String {
  #"{"id":"\#(id)","name":"Source \#(id)","createdAt":"2026-11-05T10:00:00.000Z","usedBy":\#(usedBy)}"#
}

private func list(_ sources: String...) -> StubResponse {
  json(#"{"sources":[\#(sources.joined(separator: ","))]}"#)
}

private func created(delay: TimeInterval = 0) -> StubResponse {
  json(
    #"{"id":"s1","name":"Issues","createdAt":"2026-11-05T10:00:00.000Z","usedBy":0,"address":"\#(address)"}"#,
    status: 201, delay: delay)
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

@Test func theAddressStaysOutOfDescriptionsAndDumps() {
  let created = CreatedEventSource(source: EventSource(id: "s1", name: "Issues"), address: address)
  for value in [created as Any, EventSourceDraft() as Any] {
    var dumped = ""
    dump(value, to: &dumped)
    #expect(!dumped.contains("made-up-secret"))
    #expect(!String(describing: value).contains("made-up-secret"))
  }
}

@Test func aSourceNameStopsAtTheServerLimit() {
  var draft = EventSourceDraft()
  draft.name = String(repeating: "x", count: EventSourceDraft.maxNameCharacters + 5)
  #expect(draft.name.count == EventSourceDraft.maxNameCharacters)
}

@MainActor
@Test func addingHoldsTheSheetThenShowsTheAddressUntilClosed() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if request.httpMethod == "POST" {
      try bodies.withLock { $0.append(try requestJSON(request)) }
      return created(delay: 0.05)
    }
    return list(source("s1"))
  }, test: { client in
    let board = EventSourceBoard()
    board.open()
    #expect(!board.canSave)
    board.draft?.name = "  Issues "
    board.saveDraft(client: client)
    #expect(board.isSaving)
    board.closeDraft()
    #expect(board.draft != nil)
    try await wait { board.draft?.created != nil }
    #expect(board.draft?.created?.address == address)
    #expect(!board.canSave)
    try await wait { board.isLoaded }
    #expect(board.sources.map(\.id) == ["s1"])
    #expect(bodies.withLock { $0 } == [.object(["name": .string("Issues")])])
    board.open()
    #expect(board.draft?.created?.address == address)
    board.closeDraft()
    #expect(board.draft == nil)
  })
}

@MainActor
@Test func aFailedAddKeepsTheNameAndTheRelayError() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? json(#"{"error":"Set the relay URL first"}"#, status: 400) : list()
  }, test: { client in
    let board = EventSourceBoard()
    board.open()
    board.draft?.name = "Issues"
    board.saveDraft(client: client)
    try await wait { !board.saveError.isEmpty }
    #expect(board.saveError == "Set the relay URL first")
    #expect(board.draft?.name == "Issues")
    #expect(board.canSave)
  })
}

@MainActor
@Test func aLateAddressNeverReachesANewConnection() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "POST" ? created(delay: 0.05) : list()
  }, test: { client in
    let board = EventSourceBoard()
    board.open()
    board.draft?.name = "Issues"
    board.saveDraft(client: client)
    board.reset()
    #expect(board.draft == nil)
    board.open()
    try await Task.sleep(for: .milliseconds(100))
    #expect(board.draft?.created == nil)
    #expect(board.sources.isEmpty)
  })
}

@MainActor
@Test func deletingHidesTheSourceAndARefusalBringsItBack() async throws {
  try await withClient(handler: { request in
    if request.httpMethod == "DELETE" {
      return json(#"{"error":"An automation uses this source"}"#, status: 409, delay: 0.05)
    }
    return list(source("s1"))
  }, test: { client in
    let board = EventSourceBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let row = try #require(board.sources.first)
    board.delete(row, client: client)
    #expect(board.sources.isEmpty)
    board.refresh(client: client)
    try await wait { board.errors["s1"] != nil }
    #expect(board.errors["s1"] == "An automation uses this source")
    #expect(board.sources.map(\.id) == ["s1"])
  })
}

@MainActor
@Test func aDeleteStaysDoneAndAUsedSourceCantBeDeleted() async throws {
  let deletes = Mutex(0)
  let gone = Mutex(false)
  try await withClient(handler: { request in
    if request.httpMethod == "DELETE" {
      deletes.withLock { $0 += 1 }
      gone.withLock { $0 = true }
      return StubResponse(status: 204, body: Data())
    }
    return gone.withLock { $0 } ? list(source("used", usedBy: 2)) : list(source("s1"), source("used", usedBy: 2))
  }, test: { client in
    let board = EventSourceBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let used = try #require(board.sources.last)
    #expect(!used.canDelete)
    #expect(used.deleteNote == "Remove the automations that use it first")
    board.delete(used, client: client)
    #expect(board.sources.count == 2)
    board.delete(try #require(board.sources.first), client: client)
    try await wait { deletes.withLock { $0 } == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(board.sources.map(\.id) == ["used"])
    #expect(deletes.withLock { $0 } == 1)
  })
}
