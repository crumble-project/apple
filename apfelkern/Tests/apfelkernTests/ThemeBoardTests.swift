import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private func session(_ theme: String) -> String { #"{"user":{"theme":"\#(theme)"}}"# }

private func isRead(_ request: URLRequest) -> Bool { request.httpMethod == "GET" }

private func wrote(_ request: URLRequest) -> JSONValue? { try? requestJSON(request) }

private func defaults() -> UserDefaults {
  let suite = UUID().uuidString
  guard let store = UserDefaults(suiteName: suite) else { return .standard }
  store.removePersistentDomain(forName: suite)
  return store
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

@MainActor @Test func aSignedOutChoiceStaysOnThisDeviceAndSurvivesARelaunch() {
  let store = defaults()
  let board = ThemeBoard(defaults: store)
  #expect(board.theme == .system)
  board.choose(.dark, client: nil, onFailure: { _ in Issue.record("nothing to fail") })
  #expect(board.theme == .dark)
  #expect(ThemeBoard(defaults: store).theme == .dark)
}

@MainActor @Test func theAccountsThemeReplacesTheStoredOne() async throws {
  try await withClient(handler: { _ in json(session("dark")) }, test: { client in
    let board = ThemeBoard(defaults: defaults())
    board.refresh(client: client)
    try await wait { board.theme == .dark }
  })
}

@MainActor @Test func aSessionTheServerDoesntKnowKeepsTheTheme() async throws {
  try await withClient(handler: { _ in json("null") }, test: { client in
    let store = defaults()
    let board = ThemeBoard(defaults: store)
    board.choose(.light, client: nil, onFailure: { _ in })
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.theme == .light)
  })
}

@MainActor @Test func aChoiceShowsAtOnceAndAReadCannotTakeItAway() async throws {
  let writes = Mutex<[JSONValue?]>([])
  try await withClient(handler: { request in
    if isRead(request) { return json(session("light")) }
    writes.withLock { $0.append(wrote(request)) }
    return json(#"{"status":true}"#, delay: 0.05)
  }, test: { client in
    let board = ThemeBoard(defaults: defaults())
    board.choose(.dark, client: client, session: client.session, onFailure: { _ in Issue.record("it saves") })
    #expect(board.theme == .dark)
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(30))
    try await wait { !board.isWriting }
    #expect(board.theme == .dark)
  })
  #expect(writes.withLock { $0 } == [.object(["theme": .string("dark")])])
}

@MainActor @Test func aReadFromBeforeAWriteIsDropped() async throws {
  try await withClient(handler: { request in
    isRead(request) ? json(session("light"), delay: 0.1) : json(#"{"status":true}"#)
  }, test: { client in
    let board = ThemeBoard(defaults: defaults())
    board.refresh(client: client)
    board.choose(.dark, client: client, session: client.session, onFailure: { _ in })
    try await Task.sleep(for: .milliseconds(200))
    #expect(board.theme == .dark)
  })
}

@MainActor @Test func aFailedChoiceComesBackAndReportsWhy() async throws {
  try await withClient(handler: { request in
    isRead(request) ? json(session("light")) : json(#"{"error":"nope"}"#, status: 409)
  }, test: { client in
    let store = defaults()
    let board = ThemeBoard(defaults: store)
    board.refresh(client: client)
    try await wait { board.theme == .light }
    var reported: String?
    board.choose(.dark, client: client, session: client.session, onFailure: { reported = $0 })
    #expect(board.theme == .dark)
    try await wait { reported != nil }
    #expect(board.theme == .light)
    #expect(ThemeBoard(defaults: store).theme == .light)
  })
}

@MainActor @Test func theServerEndsOnTheNewestChoice() async throws {
  let writes = Mutex<[JSONValue?]>([])
  try await withClient(handler: { request in
    writes.withLock { $0.append(wrote(request)) }
    return json(#"{"status":true}"#, delay: 0.02)
  }, test: { client in
    let board = ThemeBoard(defaults: defaults())
    board.choose(.dark, client: client, session: client.session, onFailure: { _ in })
    board.choose(.light, client: client, session: client.session, onFailure: { _ in })
    board.choose(.system, client: client, session: client.session, onFailure: { _ in })
    try await wait { writes.withLock { $0.last } == .object(["theme": .string("system")]) }
    #expect(writes.withLock { $0 }.count == 2)
    #expect(board.theme == .system)
  })
}

@MainActor @Test func aNewConnectionDropsAnOldWritesFailure() async throws {
  try await withClient(handler: { _ in json(#"{"error":"nope"}"#, status: 500, delay: 0.03) }, test: { client in
    let board = ThemeBoard(defaults: defaults())
    board.choose(.dark, client: client, session: client.session, onFailure: { _ in Issue.record("old connection") })
    board.reset()
    try await Task.sleep(for: .milliseconds(80))
    #expect(board.theme == .dark)
  })
}
